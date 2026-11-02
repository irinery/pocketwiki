import { readFile, writeFile } from 'node:fs/promises';
import registry from '../src/harness/contracts/operation-registry.json' with { type: 'json' };
import schema from '../src/harness/contracts/harness-v1.schema.json' with { type: 'json' };
import corpus from '../src/harness/contracts/corpus-v1.json' with { type: 'json' };

const uuid = '11111111-1111-4111-8111-111111111111';
const schemaFor = (operation) => schema.$defs[operation.input_schema];
const resolve = (rule) => {
  if (rule?.$ref) return schema.$defs[rule.$ref.slice('#/$defs/'.length)];
  if (rule?.anyOf) return resolve(rule.anyOf.find((candidate) => candidate.type !== 'null') ?? rule.anyOf[0]);
  return rule;
};
const previous = corpus.slots.filter(({ id }) => !id.startsWith('NH00-OP-'));
const generated = [];

for (const operation of registry.operations) {
  const inputSchema = schemaFor(operation);
  const value = validInput(operation.name, sample(inputSchema));
  const baseID = operation.test_slot;
  generated.push(slot(`${baseID}-VALID`, operation, true, structuredClone(value)));
  generated.push(slot(`${baseID}-CLOSED`, operation, false, { ...structuredClone(value), unexpected: true }));
  const primaryVariant = inputSchema.oneOf?.[0];
  for (const field of inputSchema.required ?? primaryVariant?.required ?? []) {
    const missing = structuredClone(value);
    delete missing[field];
    generated.push(slot(`${baseID}-REQUIRED-${field}`, operation, false, missing));
  }
  const typeCandidates = inputSchema.required?.length ? inputSchema.required
    : primaryVariant?.required?.length ? primaryVariant.required
      : Object.keys(inputSchema.properties ?? primaryVariant?.properties ?? {});
  const typeField = typeCandidates.find((field) => {
    const rule = resolve(inputSchema.properties?.[field] ?? primaryVariant?.properties?.[field]);
    return ['array', 'boolean', 'integer', 'object', 'string'].includes(rule?.type);
  });
  if (typeField) {
    const typeRule = resolve(inputSchema.properties?.[typeField] ?? primaryVariant.properties[typeField]);
    const invalid = typeRule.type === 'string' ? 0
      : typeRule.type === 'integer' || typeRule.type === 'boolean' ? 'wrong-type'
        : typeRule.type === 'array' ? {}
          : [];
    const changed = structuredClone(value);
    changed[typeField] = invalid;
    generated.push(slot(`${baseID}-TYPE-${typeField}`, operation, false, changed));
    if (typeRule.type === 'integer') {
      const booleanValue = structuredClone(value);
      booleanValue[typeField] = true;
      generated.push(slot(`${baseID}-TYPE-BOOLEAN-${typeField}`, operation, false, booleanValue));
    }
  }
  for (const field of operation.input_fields) {
    const branch = inputSchema.oneOf?.find((candidate) => Object.hasOwn(candidate.properties ?? {}, field.name));
    const rule = inputSchema.properties?.[field.name] ?? branch?.properties?.[field.name];
    if (!rule) continue;
    const fieldBase = branch && operation.name === 'source_control.preview' ? structuredClone(sample(branch)) : value;
    const boundaryInput = inputWithConditions(operation.name, fieldBase, field.name);
    for (const [suffix, accept, replacement] of boundaryCases(rule, boundaryInput[field.name])) {
      const changed = structuredClone(boundaryInput);
      changed[field.name] = replacement;
      generated.push(slot(`${baseID}-${field.name}-${suffix}`, operation, accept, changed));
    }
    const resolvedRule = resolve(rule);
    if (resolvedRule['x-maxBase64DecodedBytes'] !== undefined) {
      const maxDecoded = resolvedRule['x-maxBase64DecodedBytes'];
      for (const [suffix, accept, decodedBytes] of [['EDGE-DECODED-MAX', true, maxDecoded], ['ABOVE-DECODED-MAX', false, maxDecoded + 1]]) {
        const changed = structuredClone(boundaryInput);
        changed[field.name] = Buffer.alloc(decodedBytes).toString('base64');
        generated.push(slot(`${baseID}-${field.name}-${suffix}`, operation, accept, changed));
      }
    }
  }
  const condition = invalidCondition(operation.name, value);
  if (condition) generated.push(slot(`${baseID}-CONDITION`, operation, false, condition));
  for (const [suffix, accept, input] of additionalCases(operation.name, value)) {
    generated.push(slot(`${baseID}-${suffix}`, operation, accept, input));
  }
}

function inputWithConditions(name, value, field) {
  const input = structuredClone(value);
  if (name === 'permissions.respond') {
    input.answer = 'answer';
    input.option_id = 'yes';
    input.text ||= 'yes';
  }
  if (name === 'navigation.list' && ['after_position', 'after_id', 'revision'].includes(field)) {
    input.after_position ??= 0;
    input.after_id ??= uuid;
    input.revision ??= 0;
  }
  if (name === 'mcp.thread.call') {
    const readOnly = ['after_seq', 'through_seq', 'cursor'].includes(field);
    const send = ['text', 'binding_id', 'message_id', 'queue_revision'].includes(field);
    if (readOnly) Object.assign(input, { tool: 'thread.read', thread_id: uuid, through_seq: 0 });
    else if (send) Object.assign(input, { tool: field === 'queue_revision' ? 'thread.send' : 'thread.start', command_id: uuid, text: 'x', binding_id: uuid, message_id: uuid, ...(field === 'queue_revision' ? { thread_id: uuid, queue_revision: 0 } : {}) });
  }
  return input;
}

corpus.slots = [...previous, ...generated];
await writeFile(new URL('../src/harness/contracts/corpus-v1.json', import.meta.url), `${JSON.stringify(corpus, null, 2)}\n`);
console.log(`generated ${generated.length} operation corpus slots for ${registry.operations.length} registered operations`);

function slot(id, operation, accept, value) {
  return { id, schema: operation.input_schema, operation: operation.name, accept, value };
}

function sample(rule) {
  if (rule.$ref) {
    const name = rule.$ref.slice('#/$defs/'.length);
    if (name === 'uuid') return uuid;
    if (name === 'sha256') return 'a'.repeat(64);
    if (name === 'sha1') return 'a'.repeat(40);
    if (name === 'jcs') return 'null';
    return sample(schema.$defs[name]);
  }
  if (rule.anyOf) return sample(rule.anyOf.find((candidate) => candidate.type !== 'null') ?? rule.anyOf[0]);
  if (rule.oneOf) return sample(rule.oneOf[0]);
  if (Object.hasOwn(rule, 'const')) return rule.const;
  if (rule.enum) return rule.enum[0];
  switch (rule.type) {
    case 'object': return Object.fromEntries((rule.required ?? []).map((key) => [key, sample(rule.properties[key])]));
    case 'array': return arraySample(rule, rule.minItems ?? 0);
    case 'string': return stringSample(rule);
    case 'integer': return rule.minimum ?? 0;
    case 'boolean': return false;
    case 'null': return null;
    default: throw new Error(`No sample for schema: ${JSON.stringify(rule)}`);
  }
}

function stringSample(rule) {
  if (rule.pattern?.includes('{40}')) return 'a'.repeat(40);
  if (rule.pattern?.includes('{64}')) return 'a'.repeat(64);
  if (rule.pattern?.includes('^\\[A-Za-z0-9.-')) return 'github.com';
  if (rule.pattern?.includes('^\\[A-Za-z0-9+/')) return 'AA==';
  if (rule.pattern?.includes('^[') && rule.pattern.includes('/')) return 'owner/repo';
  if (rule['x-format'] === 'base64') return 'AA==';
  if (rule['x-format'] === 'base64url32') return Buffer.alloc(32).toString('base64url');
  if (rule['x-format'] === 'pairing-endpoint') return 'https://example.test/v1/harness';
  if (rule['x-format'] === 'relative-path') return 'project/root';
  return 'x'.repeat(Math.max(1, rule.minLength ?? 0, rule['x-minUtf8Bytes'] ?? 0));
}

function distinct(value, index) {
  if (typeof value === 'string') return `${value}${index ? index : ''}`;
  if (typeof value === 'number') return value + index;
  return value;
}

function arraySample(rule, length) {
  const itemRule = resolve(rule.items);
  if (itemRule?.enum) return rule.uniqueItems
    ? itemRule.enum.slice(0, length)
    : Array.from({ length }, (_, i) => itemRule.enum[i % itemRule.enum.length]);
  return Array.from({ length }, (_, i) => distinct(sample(rule.items), i));
}

function validInput(name, value) {
  const input = value;
  switch (name) {
    case 'runtime.dispatch': input.operation = 'submit'; input.text = 'submit'; break;
    case 'threads.message': delete input.prepared_id; delete input.manifest_sha256; input.text ||= 'message'; break;
    case 'permissions.respond': input.answer = 'deny'; break;
    case 'workspaces.prepare': input.mode = 'project'; input.project_id = uuid; break;
    case 'checkpoints.diff': input.scope = 'turn'; input.run_id = uuid; delete input.base_sha; break;
    case 'terminal.open': input.kind = 'pty'; break;
    case 'mcp.thread.call': input.tool = 'thread.list'; break;
    case 'source_control.preview': Object.assign(input, { operation: 'link', pr_number: 1, body: '' }); break;
    case 'navigation.update': input.action = 'pin'; input.read_through_seq = 0; delete input.before_thread_id; break;
    case 'navigation.list': input.section = 'active'; input.limit = 1; break;
  }
  return input;
}

function boundaryCases(rule, value) {
  const cases = [];
  const typeRule = resolve(rule);
  if (typeRule.type === 'integer') {
    if (typeRule.minimum !== undefined) cases.push(['EDGE-MIN', true, typeRule.minimum], ['BELOW-MIN', false, typeRule.minimum - 1]);
    if (typeRule.maximum !== undefined) cases.push(['EDGE-MAX', true, typeRule.maximum], ['ABOVE-MAX', false, typeRule.maximum + 1]);
  }
  if (typeRule.type === 'string') {
    if (typeRule['x-minUtf8Bytes'] > 0) cases.push(['EDGE-MIN-BYTES', true, 'x'.repeat(typeRule['x-minUtf8Bytes'])], ['BELOW-MIN-BYTES', false, 'x'.repeat(typeRule['x-minUtf8Bytes'] - 1)]);
    if (typeRule['x-maxUtf8Bytes'] !== undefined && typeRule['x-maxBase64DecodedBytes'] === undefined && !typeRule.pattern && typeRule['x-maxUtf8Bytes'] <= (typeRule.maxLength ?? typeRule['x-maxUtf8Bytes']) * 4) {
      const at = stringAtBytes(typeRule, typeRule['x-maxUtf8Bytes']);
      const beyond = stringAtBytes(typeRule, typeRule['x-maxUtf8Bytes'] + 1);
      if (at && beyond && at.length <= (typeRule.maxLength ?? Infinity) && beyond.length <= (typeRule.maxLength ?? Infinity)) {
        cases.push(['EDGE-MAX-BYTES', true, at], ['ABOVE-MAX-BYTES', false, beyond]);
      }
    }
    if (typeRule.minLength > 0) cases.push(['EDGE-MIN-LENGTH', true, stringAtLength(typeRule, typeRule.minLength)], ['BELOW-MIN-LENGTH', false, 'x'.repeat(typeRule.minLength - 1)]);
    if (typeRule.maxLength !== undefined && !typeRule.pattern) {
      const at = stringAtLength(typeRule, typeRule.maxLength);
      const beyond = stringAtLength(typeRule, typeRule.maxLength + 1);
      if (Buffer.byteLength(at, 'utf8') <= (typeRule['x-maxUtf8Bytes'] ?? Infinity)) cases.push(['EDGE-MAX-LENGTH', true, at]);
      if (Buffer.byteLength(beyond, 'utf8') > (typeRule['x-maxUtf8Bytes'] ?? Infinity)) {
        cases.push(['ABOVE-MAX-LENGTH', false, 'x'.repeat(typeRule.maxLength + 1)]);
      } else cases.push(['ABOVE-MAX-LENGTH', false, beyond]);
    }
  }
  if (typeRule.type === 'array') {
    if (typeRule.minItems > 0) cases.push(['EDGE-MIN-ITEMS', true, arraySample(typeRule, typeRule.minItems)], ['BELOW-MIN-ITEMS', false, arraySample(typeRule, typeRule.minItems - 1)]);
    if (typeRule.maxItems !== undefined) {
      const itemRule = resolve(typeRule.items);
      const effectiveMax = typeRule.uniqueItems && itemRule?.enum ? Math.min(typeRule.maxItems, itemRule.enum.length) : typeRule.maxItems;
      const enumLimited = typeRule.uniqueItems && itemRule?.enum && itemRule.enum.length <= typeRule.maxItems;
      const edge = arraySample(typeRule, effectiveMax);
      const beyond = enumLimited
        ? [...edge, '__outside_closed_enum__']
        : arraySample(typeRule, typeRule.maxItems + 1);
      cases.push([enumLimited ? 'EDGE-EFFECTIVE-MAX-ITEMS' : 'EDGE-MAX-ITEMS', true, edge]);
      cases.push([enumLimited ? 'ABOVE-EFFECTIVE-MAX-ITEMS' : 'ABOVE-MAX-ITEMS', false, beyond]);
    }
  }
  return cases.filter(([suffix, accept, replacement]) => JSON.stringify(replacement) !== JSON.stringify(value) && `${suffix}`);
}

function stringAtBytes(rule, bytes) {
  if (rule['x-format'] === 'git-branch') return bytes > 6 ? `codex/${'x'.repeat(bytes - 6)}` : null;
  if (rule['x-format'] === 'basename' || rule['x-format'] === 'relative-path') {
    if (rule['x-format'] === 'basename') return 'x'.repeat(bytes);
    return bytes > 2 ? `x/${'x'.repeat(bytes - 2)}` : null;
  }
  if (rule['x-format'] === 'pairing-endpoint') {
    const prefix = 'https://example.test/';
    return bytes > Buffer.byteLength(prefix) ? `${prefix}${'x'.repeat(bytes - Buffer.byteLength(prefix))}` : null;
  }
  if (rule['x-format'] === 'sha256' && bytes === 64) return 'a'.repeat(64);
  if (rule['x-format'] === 'base64url32') return bytes === 43 ? Buffer.alloc(32).toString('base64url') : null;
  if (rule['x-format'] === 'hostname') {
    let remaining = bytes;
    const labels = [];
    while (remaining > 63) { labels.push('a'.repeat(63)); remaining -= 64; }
    if (remaining < 1) return null;
    labels.push('a'.repeat(remaining));
    return labels.join('.');
  }
  if (rule['x-format'] === 'base64') {
    const decodedSize = Math.floor(bytes / 4) * 3;
    const value = Buffer.alloc(decodedSize).toString('base64');
    return Buffer.byteLength(value, 'utf8') === bytes ? value : null;
  }
  const emojiCount = Math.floor(bytes / 4);
  const remainder = bytes % 4;
  return '😀'.repeat(emojiCount) + 'x'.repeat(remainder);
}

function stringAtLength(rule, length) {
  if (rule['x-format'] === 'hostname') return stringAtBytes(rule, length);
  if (rule.pattern?.includes('/[^/')) return length < 3 ? 'x'.repeat(length) : `a/${'x'.repeat(length - 2)}`;
  return 'x'.repeat(length);
}

function invalidCondition(name, value) {
  const bad = structuredClone(value);
  switch (name) {
    case 'threads.message': bad.prepared_id = uuid; delete bad.manifest_sha256; return bad;
    case 'runtime.dispatch': bad.operation = 'cancel'; delete bad.run_id; return bad;
    case 'permissions.respond': bad.answer = 'answer'; bad.text = ''; delete bad.option_id; return bad;
    case 'workspaces.prepare': bad.mode = 'project'; delete bad.project_id; return bad;
    case 'checkpoints.diff': bad.scope = 'turn'; delete bad.run_id; return bad;
    case 'terminal.open': bad.kind = 'task'; delete bad.approval_id; return bad;
    case 'mcp.thread.call': bad.tool = 'thread.send'; return bad;
    case 'source_control.preview': bad.operation = 'create_draft'; delete bad.title; return bad;
    case 'composer.stage': bad.filename = '../escape.txt'; return bad;
    case 'workspaces.register_project': bad.root_relative = '../outside'; return bad;
    case 'navigation.update': bad.action = 'reorder'; delete bad.before_thread_id; return bad;
    case 'navigation.list': bad.after_id = uuid; return bad;
    default: return null;
  }
}

function additionalCases(name, value) {
  const valid = (suffix, input) => [suffix, true, input];
  const invalid = (suffix, input) => [suffix, false, input];
  const cases = [];
  const id2 = '22222222-2222-4222-8222-222222222222';
  const sha = 'a'.repeat(40);
  switch (name) {
    case 'workspaces.prepare': {
      const worktree = { ...structuredClone(value), mode: 'worktree', project_id: uuid, base_sha: sha, branch: 'codex/feature' };
      cases.push(valid('WORKTREE', worktree));
      cases.push(invalid('WORKTREE-BRANCH', { ...worktree, branch: '../outside' }));
      break;
    }
    case 'checkpoints.diff': {
      const branch = { ...structuredClone(value), scope: 'branch', base_sha: sha };
      delete branch.run_id;
      cases.push(valid('BRANCH', branch));
      cases.push(invalid('BRANCH-BASE', { ...branch, base_sha: undefined }));
      break;
    }
    case 'mcp.thread.call': {
      cases.push(valid('TOOL-READ', { tool: 'thread.read', thread_id: uuid }));
      cases.push(valid('TOOL-READ-BOUNDARY', { tool: 'thread.read', thread_id: uuid, through_seq: 10 }));
      cases.push(invalid('TOOL-READ-CURSOR', { tool: 'thread.read', thread_id: uuid, cursor: 'next' }));
      cases.push(valid('TOOL-START', { tool: 'thread.start', command_id: uuid, text: 'start', binding_id: uuid, message_id: id2 }));
      cases.push(invalid('TOOL-START-TEXT', { tool: 'thread.start', command_id: uuid, text: '', binding_id: uuid, message_id: id2 }));
      cases.push(valid('TOOL-SEND', { tool: 'thread.send', command_id: uuid, thread_id: uuid, text: 'send', binding_id: uuid, message_id: id2, queue_revision: 0 }));
      cases.push(invalid('TOOL-SEND-CAS', { tool: 'thread.send', command_id: uuid, thread_id: uuid, text: 'send', binding_id: uuid, message_id: id2 }));
      cases.push(valid('TOOL-INTERRUPT', { tool: 'thread.interrupt', command_id: uuid, thread_id: uuid, queue_revision: 0 }));
      cases.push(invalid('TOOL-LIST-MUTATION', { tool: 'thread.list', command_id: uuid }));
      break;
    }
    case 'permissions.respond': {
      cases.push(valid('ANSWER-TEXT', { ...structuredClone(value), answer: 'answer', text: 'yes' }));
      cases.push(valid('ANSWER-OPTION', { ...structuredClone(value), answer: 'answer', option_id: 'yes' }));
      cases.push(invalid('ANSWER-EMPTY', { ...structuredClone(value), answer: 'answer', text: '', option_id: undefined }));
      break;
    }
    case 'source_control.preview': {
      const common = { thread_id: uuid, host: 'github.com', repository: 'owner/repo', head_sha: sha };
      cases.push(valid('VARIANT-CREATE', { ...common, operation: 'create_draft', body: 'draft', title: 'Title', base_branch: 'main', head_branch: 'feature' }));
      cases.push(valid('VARIANT-COMMENT', { ...common, operation: 'comment', body: 'comment', pr_number: 1 }));
      cases.push(valid('VARIANT-REVIEW', { ...common, operation: 'review', body: '', pr_number: 1, review_event: 'approve' }));
      cases.push(valid('VARIANT-MERGE', { ...common, operation: 'merge', body: '', pr_number: 1, merge_method: 'squash' }));
      cases.push(invalid('VARIANT-MERGE-METHOD', { ...common, operation: 'merge', body: '', pr_number: 1, merge_method: 'fast-forward' }));
      break;
    }
    case 'navigation.update': {
      cases.push(valid('REORDER', { ...structuredClone(value), action: 'reorder', before_thread_id: id2 }));
      cases.push(valid('MARK-READ', { ...structuredClone(value), action: 'mark_read', read_through_seq: 4 }));
      break;
    }
    case 'environments.pair':
      cases.push(valid('ENDPOINT-LOOPBACK', { ...structuredClone(value), endpoint: 'http://127.0.0.2/pair' }));
      cases.push(invalid('ENDPOINT-CREDENTIALS', { ...structuredClone(value), endpoint: 'https://user:secret@example.test/pair' }));
      cases.push(invalid('ENDPOINT-HTTP-REMOTE', { ...structuredClone(value), endpoint: 'http://example.test/pair' }));
      cases.push(invalid('ENDPOINT-EMPTY-QUERY', { ...structuredClone(value), endpoint: 'https://example.test/pair?' }));
      break;
    case 'terminal.input':
      cases.push(invalid('DECODED-MAX', { ...structuredClone(value), data_base64: Buffer.alloc(65_537).toString('base64') }));
      break;
    case 'environments.challenge': {
      const scopes = ['read','submit','approve','execute','context.read','memory.personal.read','memory.write','scm.write','scm.merge'];
      cases.push(valid('SCOPE-MAX', { ...structuredClone(value), requested_scopes: scopes }));
      cases.push(invalid('SCOPE-DUPLICATE', { ...structuredClone(value), requested_scopes: ['read','read'] }));
      break;
    }
  }
  return cases;
}
