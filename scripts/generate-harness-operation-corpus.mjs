import { readFile, writeFile } from 'node:fs/promises';
import registry from '../src/harness/contracts/operation-registry.json' with { type: 'json' };
import schema from '../src/harness/contracts/harness-v1.schema.json' with { type: 'json' };
import corpus from '../src/harness/contracts/corpus-v1.json' with { type: 'json' };

const uuid = '11111111-1111-4111-8111-111111111111';
const schemaFor = (operation) => schema.$defs[operation.input_schema];
const previous = corpus.slots.filter(({ id }) => !id.startsWith('NH00-OP-'));
const generated = [];

for (const operation of registry.operations) {
  const value = validInput(operation.name, sample(schemaFor(operation)));
  const baseID = operation.test_slot;
  generated.push(slot(`${baseID}-VALID`, operation, true, structuredClone(value)));
  generated.push(slot(`${baseID}-CLOSED`, operation, false, { ...structuredClone(value), unexpected: true }));
  for (const field of operation.input_fields) {
    const rule = schemaFor(operation).properties?.[field.name];
    if (!rule) continue;
    for (const [suffix, invalid] of boundaryCases(rule, value[field.name])) {
      const changed = structuredClone(value);
      changed[field.name] = invalid;
      generated.push(slot(`${baseID}-${field.name}-${suffix}`, operation, false, changed));
    }
  }
  const condition = invalidCondition(operation.name, value);
  if (condition) generated.push(slot(`${baseID}-CONDITION`, operation, false, condition));
  for (const [suffix, accept, input] of additionalCases(operation.name, value)) {
    generated.push(slot(`${baseID}-${suffix}`, operation, accept, input));
  }
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
    case 'array': return Array.from({ length: rule.minItems ?? 0 }, (_, i) => distinct(sample(rule.items), i));
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
  const typeRule = rule.anyOf?.find((candidate) => candidate.type !== 'null') ?? rule;
  if (typeRule.type === 'integer') {
    if (typeRule.minimum !== undefined) cases.push(['MIN', typeRule.minimum - 1]);
    if (typeRule.maximum !== undefined) cases.push(['MAX', typeRule.maximum + 1]);
  }
  if (typeRule.type === 'string') {
    if (typeRule['x-minUtf8Bytes'] > 0) cases.push(['MIN', 'x'.repeat(typeRule['x-minUtf8Bytes'] - 1)]);
    if (typeRule['x-maxUtf8Bytes'] !== undefined) cases.push(['MAX', 'x'.repeat(typeRule['x-maxUtf8Bytes'] + 1)]);
    if (typeRule.minLength > 0) cases.push(['MIN', 'x'.repeat(typeRule.minLength - 1)]);
    if (typeRule.maxLength !== undefined) cases.push(['MAX', 'x'.repeat(typeRule.maxLength + 1)]);
  }
  if (typeRule.type === 'array') {
    if (typeRule.minItems > 0) cases.push(['MIN', []]);
    if (typeRule.maxItems !== undefined) cases.push(['MAX', Array.from({ length: typeRule.maxItems + 1 }, (_, i) => distinct(sample(typeRule.items), i))]);
  }
  return cases.filter(([suffix, invalid]) => JSON.stringify(invalid) !== JSON.stringify(value) && `${suffix}`);
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
