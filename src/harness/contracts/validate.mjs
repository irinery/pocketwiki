import schema from './harness-v1.schema.json' with { type: 'json' };

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateAgainst(schemaName, value) {
  const definition = schema.$defs[schemaName];
  if (!definition) throw new TypeError(`Unknown Harness schema: ${schemaName}`);
  const errors = [];
  visit(definition, value, '$', errors);
  return { valid: errors.length === 0, errors };
}

export function assertValid(schemaName, value) {
  const result = validateAgainst(schemaName, value);
  if (!result.valid) {
    const error = new TypeError(`${schemaName} rejected: ${result.errors.join('; ')}`);
    error.validationErrors = result.errors;
    throw error;
  }
  return value;
}

export function validateCommandEnvelope(value, registry) {
  const errors = validateAgainst('command', value).errors;
  const operation = typeof value?.operation === 'string'
    ? registry.find((entry) => entry.name === value.operation)
    : undefined;
  if (!operation) errors.push('$.operation is not a registered v1 operation');
  else if (operation.class !== 'mutation') errors.push('$.operation is not a mutation operation');
  return { valid: errors.length === 0, errors, operation };
}

function visit(rule, value, path, errors) {
  if (rule.$ref) {
    const target = rule.$ref.replace('#/$defs/', '');
    visit(schema.$defs[target], value, path, errors);
    return;
  }
  if (rule.oneOf) {
    const matches = rule.oneOf.filter((candidate) => {
      const candidateErrors = [];
      visit(candidate, value, path, candidateErrors);
      return candidateErrors.length === 0;
    }).length;
    if (matches !== 1) errors.push(`${path} must match exactly one allowed variant`);
  }
  if (rule.not) {
    const candidateErrors = [];
    visit(rule.not, value, path, candidateErrors);
    if (candidateErrors.length === 0) errors.push(`${path} matches a forbidden shape`);
  }

  if (rule.type === 'object') {
    if (!isRecord(value)) return errors.push(`${path} must be an object`);
    for (const key of rule.required ?? []) if (!Object.hasOwn(value, key)) errors.push(`${path}.${key} is required`);
    if (rule.additionalProperties === false) {
      for (const key of Object.keys(value)) if (!Object.hasOwn(rule.properties ?? {}, key)) errors.push(`${path}.${key} is not allowed`);
    }
    for (const [key, propertyRule] of Object.entries(rule.properties ?? {})) {
      if (Object.hasOwn(value, key)) visit(propertyRule, value[key], `${path}.${key}`, errors);
    }
  } else if (rule.type === 'array') {
    if (!Array.isArray(value)) return errors.push(`${path} must be an array`);
    if (rule.minItems !== undefined && value.length < rule.minItems) errors.push(`${path} has fewer than ${rule.minItems} items`);
    if (rule.maxItems !== undefined && value.length > rule.maxItems) errors.push(`${path} exceeds ${rule.maxItems} items`);
    if (rule.uniqueItems && new Set(value.map((item) => JSON.stringify(item))).size !== value.length) errors.push(`${path} items must be unique`);
    if (rule.items) value.forEach((item, index) => visit(rule.items, item, `${path}[${index}]`, errors));
  } else if (rule.type === 'string') {
    if (typeof value !== 'string') return errors.push(`${path} must be a string`);
    if (rule.format === 'uuid' && !uuidPattern.test(value)) errors.push(`${path} must be a UUID`);
    if (rule.pattern && !(new RegExp(rule.pattern).test(value))) errors.push(`${path} does not match ${rule.pattern}`);
    if (rule.minLength !== undefined && Buffer.byteLength(value, 'utf8') < rule.minLength) errors.push(`${path} is shorter than ${rule.minLength} bytes`);
    if (rule.maxLength !== undefined && Buffer.byteLength(value, 'utf8') > rule.maxLength) errors.push(`${path} exceeds ${rule.maxLength} bytes`);
    if (rule['x-maxUtf8Bytes'] !== undefined && Buffer.byteLength(value, 'utf8') > rule['x-maxUtf8Bytes']) errors.push(`${path} exceeds ${rule['x-maxUtf8Bytes']} UTF-8 bytes`);
    if (rule['x-format'] === 'jcs' && !isCanonicalEntityKey(value)) errors.push(`${path} must be canonical JSON`);
  } else if (rule.type === 'integer') {
    if (!Number.isSafeInteger(value)) return errors.push(`${path} must be an integer`);
    if (rule.minimum !== undefined && value < rule.minimum) errors.push(`${path} is below ${rule.minimum}`);
  } else if (rule.type === 'boolean' && typeof value !== 'boolean') {
    errors.push(`${path} must be a boolean`);
  }
  if (Object.hasOwn(rule, 'const') && value !== rule.const) errors.push(`${path} must equal ${JSON.stringify(rule.const)}`);
  if (rule.enum && !rule.enum.includes(value)) errors.push(`${path} is outside the allowed enum`);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isCanonicalEntityKey(value) {
  if (Buffer.byteLength(value, 'utf8') > 1024) return false;
  try {
    return canonicalJSON(JSON.parse(value)) === value;
  } catch {
    return false;
  }
}

function canonicalJSON(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (isRecord(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
  throw new TypeError('Unsupported canonical JSON value');
}
