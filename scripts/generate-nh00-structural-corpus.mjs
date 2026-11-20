import { readFile, writeFile } from 'node:fs/promises';
import schema from '../src/harness/contracts/harness-v1.schema.json' with { type: 'json' };
import corpus from '../src/harness/contracts/corpus-v1.json' with { type: 'json' };

const uuid = '11111111-1111-4111-8111-111111111111';
const prefix = 'NH00-STRUCT-';
const slots = [];

for (const snapshotVariant of schema.$defs.snapshotEnvelope.oneOf) {
  const module = snapshotVariant.properties.module.const;
  const snapshotName = snapshotVariant.properties.data.$ref.slice('#/$defs/'.length);
  const snapshotSchema = schema.$defs[snapshotName];
  const emptySnapshot = sample(snapshotSchema);
  slots.push(slot(`${prefix}SNAPSHOT-${module}-CURSOR-ABSENT`, 'snapshotEnvelope', true, { module, data: emptySnapshot }));
  slots.push(slot(`${prefix}SNAPSHOT-${module}-CURSOR-NULL`, 'snapshotEnvelope', false, { module, data: { ...structuredClone(emptySnapshot), next_cursor: null } }));
  for (const [field, rule] of Object.entries(snapshotSchema.properties ?? {})) {
    const collection = rule.type === 'array' ? rule : null;
    const target = collection?.items?.$ref ?? rule.$ref;
    if (!target?.startsWith('#/$defs/')) continue;
    const entity = target.slice('#/$defs/'.length);
    if (schema.$defs[entity]?.type !== 'object') continue;
    if (!collection && snapshotSchema.required?.includes(field)) {
      const missingSingleton = sample(snapshotSchema);
      delete missingSingleton[field];
      slots.push(slot(`${prefix}SNAPSHOT-${module}-${field}-SINGLETON-MISSING`, 'snapshotEnvelope', false, { module, data: missingSingleton }));
    }
    const sampleSnapshot = sample(snapshotSchema);
    const validEntity = sample(schema.$defs[entity]);
    sampleSnapshot[field] = collection ? [validEntity] : validEntity;
    slots.push(slot(`${prefix}SNAPSHOT-${module}-${entity}-VALID`, 'snapshotEnvelope', true, { module, data: sampleSnapshot }));

    const invalidSnapshot = structuredClone(sampleSnapshot);
    const invalidEntity = collection ? invalidSnapshot[field][0] : invalidSnapshot[field];
    if (isRecord(invalidEntity)) invalidEntity.__unexpected = true;
    slots.push(slot(`${prefix}SNAPSHOT-${module}-${entity}-NESTED-EXTRA`, 'snapshotEnvelope', false, { module, data: invalidSnapshot }));
  }
}

for (const streamVariant of schema.$defs.streamEnvelope.oneOf) {
  if (streamVariant.properties.delivery?.const !== 'inline') continue;
  const module = streamVariant.properties.module.const;
  const eventName = streamVariant.properties.payload.$ref.slice('#/$defs/'.length);
  const eventUnion = schema.$defs[eventName];
  for (let index = 0; index < (eventUnion.oneOf ?? []).length; index++) {
    const validEvent = sample(eventUnion.oneOf[index]);
    const base = sample(streamVariant);
    base.payload = validEvent;
    const name = `${validEvent.entity_type ?? `${module}-${index}`}-${validEvent.change ?? index}`;
    slots.push(slot(`${prefix}EVENT-${module}-${name}-VALID`, 'streamEnvelope', true, base));

    const invalid = structuredClone(base);
    invalid.payload.__unexpected = true;
    slots.push(slot(`${prefix}EVENT-${module}-${name}-CLOSED`, 'streamEnvelope', false, invalid));
  }
}

for (const entity of schema['x-entityTypes'] ?? []) {
  const definition = schema.$defs[entity];
  if (!definition) continue;
  const base = sample(definition);
  slots.push(slot(`${prefix}ENTITY-${entity}-VALID`, entity, true, structuredClone(base)));
  const closed = structuredClone(base);
  closed.__unexpected = true;
  slots.push(slot(`${prefix}ENTITY-${entity}-CLOSED`, entity, false, closed));

  for (const [field, rawRule] of Object.entries(definition.properties ?? {})) {
    const rule = resolve(rawRule);
    if (!rule) continue;
    const current = base[field];
    if (rawRule.anyOf?.some((candidate) => candidate.type === 'null')) addEntityCase(entity, field, 'NULL', true, null);
    if (rule.type === 'integer' && !Object.hasOwn(rule, 'const')) {
      if (rule.minimum !== undefined) addEntityCase(entity, field, 'EDGE-MIN', true, rule.minimum);
      if (rule.minimum !== undefined && rule.minimum > -9007199254740991) addEntityCase(entity, field, 'BELOW-MIN', false, rule.minimum - 1);
      if (rule.maximum !== undefined) addEntityCase(entity, field, 'EDGE-MAX', true, rule.maximum);
      if (rule.maximum !== undefined && rule.maximum <= 9007199254740991) addEntityCase(entity, field, 'ABOVE-MAX', false, rule.maximum + 1);
    }
    if (rule.type === 'string') {
      if (rule['x-maxBase64DecodedBytes'] !== undefined) {
        const limit = rule['x-maxBase64DecodedBytes'];
        addEntityCase(entity, field, 'EDGE-DECODED-MAX', true, Buffer.alloc(limit).toString('base64'));
        addEntityCase(entity, field, 'ABOVE-DECODED-MAX', false, Buffer.alloc(limit + 1).toString('base64'));
      } else if (rule['x-maxUtf8Bytes'] !== undefined && !rule.pattern && !rule.enum) {
        const conditional = rule['x-maxUtf8BytesBy'];
        if (conditional) {
          for (const [parentField, variants] of Object.entries(conditional)) {
            for (const [discriminator, limit] of Object.entries(variants)) {
              addEntityCase(entity, field, `EDGE-${parentField}-${discriminator}`, true, stringAtBytes(rule, limit), { [parentField]: discriminator });
              addEntityCase(entity, field, `ABOVE-${parentField}-${discriminator}`, false, stringAtBytes(rule, limit + 1), { [parentField]: discriminator });
            }
          }
        } else {
          const at = stringAtBytes(rule, rule['x-maxUtf8Bytes']);
          const beyond = stringAtBytes(rule, rule['x-maxUtf8Bytes'] + 1);
          if (at && beyond) {
            addEntityCase(entity, field, 'EDGE-MAX-BYTES', true, at);
            addEntityCase(entity, field, 'ABOVE-MAX-BYTES', false, beyond);
          }
        }
      }
    }
    if (rule.type === 'array' && rule.maxItems !== undefined) {
      const itemRule = resolve(rule.items);
      const enumLimited = rule.uniqueItems && itemRule?.enum && itemRule.enum.length <= rule.maxItems;
      const crossLimited = entity === 'PermissionRequest' && field === 'options';
      const effectiveMax = crossLimited ? 10 : enumLimited ? itemRule.enum.length : rule.maxItems;
      const effectiveLimit = crossLimited || enumLimited;
      const edge = arraySample(rule, effectiveMax);
      const beyond = arraySample(rule, effectiveMax + 1);
      addEntityCase(entity, field, effectiveLimit ? 'EDGE-EFFECTIVE-MAX-ITEMS' : 'EDGE-MAX-ITEMS', true, edge);
      addEntityCase(entity, field, effectiveLimit ? 'ABOVE-EFFECTIVE-MAX-ITEMS' : 'ABOVE-MAX-ITEMS', false, beyond);
      if (rule.minItems !== undefined) addEntityCase(entity, field, 'EDGE-MIN-ITEMS', true, arraySample(rule, rule.minItems));
    }
    if (current === undefined && rule.type === 'string' && rule.enum?.length) {
      addEntityCase(entity, field, 'ENUM-UNKNOWN', false, '__unknown__');
    }
  }
}

// R1 defines the projection key. E0 validators only validate JCS syntax, so
// retain their existing acceptance of a different valid key until enforcement is introduced.
const runtimeEvent = structuredClone(slots.find(({ id }) => id === `${prefix}EVENT-runtime-RuntimeEvent-upsert-VALID`).value);
runtimeEvent.payload.entity_key = JSON.stringify(runtimeEvent.payload.value.event_id);
slots.push(slot(`${prefix}E1-RUNTIME-EVENT-CANONICAL-KEY`, 'streamEnvelope', true, structuredClone(runtimeEvent)));
runtimeEvent.payload.entity_key = JSON.stringify('22222222-2222-4222-8222-222222222222');
slots.push(slot(`${prefix}E1-RUNTIME-EVENT-LEGACY-KEY-ACCEPTED`, 'streamEnvelope', true, runtimeEvent));

// Additive E1 contracts: exercise both names and reject cross-boundary shapes.
const dispatch = { receipt_id: uuid, revision: 0, state: 'accepted' };
const http = { command_id: uuid, receipt_id: uuid, environment_id: uuid, revision: 0, state: 'pending', duplicate: false };
for (const [name, target, valid, value] of [
  ['DISPATCH-VALID', 'runtimeDispatchResult', true, dispatch],
  ['LEGACY-VALID', 'commandReceipt', true, dispatch],
  ['HTTP-VALID', 'httpCommandReceipt', true, http],
  ['HTTP-RESULT-REF', 'httpCommandReceipt', true, { ...http, result_ref: uuid }],
  ['HTTP-REJECT-DISPATCH', 'httpCommandReceipt', false, dispatch],
  ['DISPATCH-REJECT-HTTP', 'runtimeDispatchResult', false, http],
  ['LEGACY-REJECT-HTTP', 'commandReceipt', false, http],
  ['HTTP-EXTRA', 'httpCommandReceipt', false, { ...http, extra: true }],
  ['HTTP-NULL-RESULT', 'httpCommandReceipt', true, { ...http, result_ref: null }],
  ['HTTP-BAD-DUPLICATE', 'httpCommandReceipt', false, { ...http, duplicate: 0 }],
  ['HTTP-BAD-STATE', 'httpCommandReceipt', false, { ...http, state: 'duplicate' }],
  ['HTTP-REVISION-UNSAFE', 'httpCommandReceipt', false, { ...http, revision: 9007199254740992 }],
]) slots.push(slot(`${prefix}E1-${name}`, target, valid, value));

const unsafeStream = structuredClone(runtimeEvent);
unsafeStream.seq = 9007199254740992;
slots.push(slot(`${prefix}E1-STREAM-SEQ-UNSAFE`, 'streamEnvelope', false, unsafeStream));

const previous = corpus.slots.filter(({ id }) => !id.startsWith(prefix));
corpus.slots = [...previous, ...slots];
await writeFile(new URL('../src/harness/contracts/corpus-v1.json', import.meta.url), `${JSON.stringify(corpus, null, 2)}\n`);
console.log(`generated ${slots.length} snapshot/entity/event structural slots`);

function resolve(rule) {
  if (rule?.$ref) return schema.$defs[rule.$ref.slice('#/$defs/'.length)];
  if (rule?.anyOf) return resolve(rule.anyOf.find((candidate) => candidate.type !== 'null') ?? rule.anyOf[0]);
  return rule;
}

function arraySample(rule, length) {
  const itemRule = resolve(rule.items);
  if (itemRule?.enum) return rule.uniqueItems
    ? itemRule.enum.slice(0, length)
    : Array.from({ length }, (_, index) => itemRule.enum[index % itemRule.enum.length]);
  return Array.from({ length }, () => sample(rule.items));
}

function addEntityCase(entity, field, suffix, accept, value, parentOverrides = {}) {
  const candidate = sample(schema.$defs[entity]);
  Object.assign(candidate, parentOverrides);
  candidate[field] = value;
  if (entity === 'PermissionRequest' && field === 'options') {
    candidate.kind = 'question';
    candidate.action = { kind: 'question', question: 'Review this request', options: structuredClone(value) };
  }
  slots.push(slot(`${prefix}ENTITY-${entity}-${field}-${suffix}`, entity, accept, candidate));
}

function stringAtBytes(rule, bytes) {
  if (rule['x-format'] === 'base64') {
    const value = Buffer.alloc(Math.floor(bytes / 4) * 3).toString('base64');
    return Buffer.byteLength(value, 'utf8') === bytes ? value : null;
  }
  if (rule['x-format'] === 'hostname') {
    let remaining = bytes;
    const labels = [];
    while (remaining > 63) { labels.push('a'.repeat(63)); remaining -= 64; }
    if (remaining < 1) return null;
    labels.push('a'.repeat(remaining));
    return labels.join('.');
  }
  if (rule['x-format'] === 'basename') return 'x'.repeat(bytes);
  if (rule['x-format'] === 'relative-path') return bytes > 2 ? `x/${'x'.repeat(bytes - 2)}` : null;
  if (rule['x-format'] === 'git-branch') return bytes > 6 ? `codex/${'x'.repeat(bytes - 6)}` : null;
  const emoji = '😀'.repeat(Math.floor(bytes / 4));
  return emoji + 'x'.repeat(bytes % 4);
}

function slot(id, schemaName, accept, value) { return { id, schema: schemaName, accept, value }; }
function isRecord(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }

function sample(rule) {
  if (rule.$ref) return sample(schema.$defs[rule.$ref.slice('#/$defs/'.length)]);
  if (rule.anyOf) return sample(rule.anyOf.find((candidate) => candidate.type !== 'null') ?? rule.anyOf[0]);
  if (rule.oneOf) return sample(rule.oneOf[0]);
  if (Object.hasOwn(rule, 'const')) return structuredClone(rule.const);
  if (rule.enum) return rule.enum[0];
  switch (rule.type) {
    case 'object': {
      const value = Object.fromEntries((rule.required ?? []).map((key) => [key, sample(rule.properties[key])]));
      if (Object.hasOwn(value, 'action') && Object.hasOwn(value, 'options') && Object.hasOwn(value, 'request_id')) {
        value.kind = value.action.kind;
        value.options = value.kind === 'question' ? (value.action.options ?? []) : [];
      }
      return value;
    }
    case 'array': return Array.from({ length: rule.minItems ?? 0 }, () => sample(rule.items));
    case 'string': return sampleString(rule);
    case 'integer': return rule.minimum ?? 0;
    case 'boolean': return false;
    case 'null': return null;
    default: return {};
  }
}

function sampleString(rule) {
  if (rule.enum) return rule.enum[0];
  if (rule.format === 'uuid') return uuid;
  if (rule.pattern?.includes('[^/')) return 'owner/repo';
  if (rule.pattern?.includes('{40}')) return 'a'.repeat(40);
  if (rule.pattern?.includes('{64}')) return 'a'.repeat(64);
  if (rule['x-format'] === 'jcs') return 'null';
  if (rule['x-format'] === 'hostname') return 'example.test';
  if (rule['x-format'] === 'pairing-endpoint') return 'https://example.test/pair';
  if (rule['x-format'] === 'relative-path') return 'project/root';
  if (rule['x-format'] === 'basename') return 'file.txt';
  if (rule['x-format'] === 'git-branch') return 'codex/feature';
  if (rule['x-format'] === 'base64') return 'AA==';
  if (rule['x-format'] === 'base64url32') return Buffer.alloc(32).toString('base64url');
  if (rule.format === 'date-time') return '2026-11-02T12:00:00Z';
  const min = Math.max(1, rule.minLength ?? 0, rule['x-minUtf8Bytes'] ?? 0);
  return 'x'.repeat(min);
}
