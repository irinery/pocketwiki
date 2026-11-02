import schema from './harness-v1.schema.json' with { type: 'json' };

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateAgainst(schemaName, value, operationName) {
  const definition = schema.$defs[schemaName];
  if (!definition) throw new TypeError(`Unknown Harness schema: ${schemaName}`);
  const errors = [];
  visit(definition, value, '$', errors);
  if (schemaName === 'command' && value?.operation === 'runtime.dispatch' && errors.length === 0) {
    if (value.input.command_id !== value.command_id) errors.push('$.input.command_id must equal $.command_id');
    if (value.input.expected_revision !== value.expected_revision) errors.push('$.input.expected_revision must equal $.expected_revision');
  }
  if (schemaName === 'command' && errors.length === 0 && typeof value?.operation === 'string') {
    const inputValidation = validateOperationInput(value.operation, value.input);
    errors.push(...inputValidation.errors.map((error) => `$.input${error.slice(1)}`));
  }
  validateSemantics(value, '$', errors);
  if (operationName) checkOperationInput(operationName, value, errors);
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
  else if (operation.contract_status === 'blocked') errors.push('$.operation contract is blocked');
  if (operation?.name === 'runtime.dispatch') {
    if (value?.input?.command_id !== value?.command_id) errors.push('$.input.command_id must equal $.command_id');
    if (value?.input?.expected_revision !== value?.expected_revision) errors.push('$.input.expected_revision must equal $.expected_revision');
  }
  return { valid: errors.length === 0, errors, operation };
}

export function validateOperationInput(operationName, value) {
  const schemaName = `operationInput_${operationName.replaceAll('.', '_').replaceAll('-', '_')}`;
  const result = validateAgainst(schemaName, value, operationName);
  return { ...result, operation: operationName };
}

function validateSemantics(value, path, errors) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => validateSemantics(item, `${path}[${index}]`, errors));
    return;
  }
  if (!isRecord(value)) return;
  if (Object.hasOwn(value, 'request_id') && Object.hasOwn(value, 'action') && Object.hasOwn(value, 'options')) {
    if (value.kind !== value.action?.kind) errors.push(`${path}.kind must equal action.kind`);
    const expectedOptions = value.kind === 'question' ? value.action?.options : [];
    if (!jsonEqual(value.options, expectedOptions)) errors.push(`${path}.options must match the action options for its kind`);
  }
  for (const [key, child] of Object.entries(value)) validateSemantics(child, `${path}.${key}`, errors);
}

function checkOperationInput(operation, value, errors) {
  const fail = (condition) => { if (!condition) errors.push(`$ violates ${operation} input conditions`); };
  switch (operation) {
    case 'threads.message':
      fail(Object.hasOwn(value, 'prepared_id') === Object.hasOwn(value, 'manifest_sha256'));
      break;
    case 'runtime.dispatch':
      fail(value.operation === 'submit' ? !Object.hasOwn(value, 'run_id') && value.text.length > 0 : Object.hasOwn(value, 'run_id'));
      break;
    case 'permissions.respond':
      fail(value.answer !== 'answer' || Boolean(value.text) || Boolean(value.option_id));
      break;
    case 'workspaces.prepare':
      fail(value.mode === 'scratch' ? !Object.hasOwn(value, 'project_id') : Object.hasOwn(value, 'project_id'));
      fail(value.mode !== 'worktree' || (Object.hasOwn(value, 'base_sha') && Object.hasOwn(value, 'branch')));
      break;
    case 'checkpoints.diff':
      fail(value.scope === 'turn' ? Object.hasOwn(value, 'run_id') && !Object.hasOwn(value, 'base_sha') : Object.hasOwn(value, 'base_sha') && !Object.hasOwn(value, 'run_id'));
      break;
    case 'terminal.open':
      fail(value.kind !== 'task' || Object.hasOwn(value, 'approval_id'));
      break;
    case 'mcp.thread.call': {
      const rules = {
        'thread.list': ['project_id','text','after_seq','through_seq','cursor','binding_id','message_id','queue_revision'],
        'thread.read': ['project_id','text','binding_id','message_id','queue_revision'],
        'thread.start': ['thread_id','after_seq','through_seq','cursor','queue_revision'],
        'thread.send': ['project_id','after_seq','through_seq','cursor'],
        'thread.interrupt': ['project_id','text','after_seq','through_seq','cursor','binding_id','message_id']
      };
      const forbidden = rules[value.tool] ?? [];
      fail(forbidden.every((field) => !Object.hasOwn(value, field)));
      const required = {
        'thread.start': ['command_id','project_id','text','binding_id','message_id'],
        'thread.send': ['command_id','thread_id','text','binding_id','message_id','queue_revision'],
        'thread.interrupt': ['command_id','thread_id','queue_revision'],
        'thread.read': ['thread_id'],
        'thread.list': []
      }[value.tool] ?? [];
      fail(required.every((field) => Object.hasOwn(value, field)));
      break;
    }
    case 'source_control.preview': {
      const preview = Object.fromEntries(['host','repository','operation','pr_number','head_sha','body','title','base_branch','head_branch','review_event','merge_method'].filter((key) => Object.hasOwn(value, key)).map((key) => [key, value[key]]));
      const result = validateAgainst('ForgePreview', preview);
      fail(result.valid);
      break;
    }
    case 'navigation.update':
      fail(value.action === 'reorder' ? Object.hasOwn(value, 'before_thread_id') : !Object.hasOwn(value, 'before_thread_id'));
      break;
    case 'navigation.list':
      fail(Object.hasOwn(value, 'after_position') === Object.hasOwn(value, 'after_id'));
      fail((Object.hasOwn(value, 'after_id') || Object.hasOwn(value, 'after_position')) === Object.hasOwn(value, 'revision'));
      break;
    default:
      break;
  }
}

function jsonEqual(left, right) {
  try { return canonicalJSON(left) === canonicalJSON(right); } catch { return false; }
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
  if (rule.anyOf) {
    const matches = rule.anyOf.some((candidate) => {
      const candidateErrors = [];
      visit(candidate, value, path, candidateErrors);
      return candidateErrors.length === 0;
    });
    if (!matches) errors.push(`${path} must match an allowed value`);
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
    if (rule.minLength !== undefined && Array.from(value).length < rule.minLength) errors.push(`${path} is shorter than ${rule.minLength} characters`);
    if (rule.maxLength !== undefined && Array.from(value).length > rule.maxLength) errors.push(`${path} exceeds ${rule.maxLength} characters`);
    if (rule['x-minUtf8Bytes'] !== undefined && Buffer.byteLength(value, 'utf8') < rule['x-minUtf8Bytes']) errors.push(`${path} is shorter than ${rule['x-minUtf8Bytes']} UTF-8 bytes`);
    if (rule['x-maxUtf8Bytes'] !== undefined && Buffer.byteLength(value, 'utf8') > rule['x-maxUtf8Bytes']) errors.push(`${path} exceeds ${rule['x-maxUtf8Bytes']} UTF-8 bytes`);
    if (rule['x-format'] === 'base64' && !isBase64(value)) errors.push(`${path} must be base64`);
    if (rule['x-format'] === 'jcs' && !isCanonicalEntityKey(value)) errors.push(`${path} must be canonical JSON`);
  } else if (rule.type === 'integer') {
    if (!Number.isSafeInteger(value)) return errors.push(`${path} must be an integer`);
    if (rule.minimum !== undefined && value < rule.minimum) errors.push(`${path} is below ${rule.minimum}`);
    if (rule.maximum !== undefined && value > rule.maximum) errors.push(`${path} exceeds ${rule.maximum}`);
  } else if (rule.type === 'boolean' && typeof value !== 'boolean') {
    errors.push(`${path} must be a boolean`);
  } else if (rule.type === 'null' && value !== null) {
    errors.push(`${path} must be null`);
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

function isBase64(value) {
  if (value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return false;
  return Buffer.from(value, 'base64').toString('base64') === value;
}

function canonicalJSON(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (isRecord(value)) return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
  throw new TypeError('Unsupported canonical JSON value');
}
