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
  for (const [field, rule] of Object.entries(snapshotSchema.properties ?? {})) {
    const collection = rule.type === 'array' ? rule : null;
    const target = collection?.items?.$ref ?? rule.$ref;
    if (!target?.startsWith('#/$defs/')) continue;
    const entity = target.slice('#/$defs/'.length);
    if (schema.$defs[entity]?.type !== 'object') continue;
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
    const name = validEvent.entity_type ?? `${module}-${index}`;
    slots.push(slot(`${prefix}EVENT-${module}-${name}-VALID`, 'streamEnvelope', true, base));

    const invalid = structuredClone(base);
    invalid.payload.__unexpected = true;
    slots.push(slot(`${prefix}EVENT-${module}-${name}-CLOSED`, 'streamEnvelope', false, invalid));
  }
}

const previous = corpus.slots.filter(({ id }) => !id.startsWith(prefix));
corpus.slots = [...previous, ...slots];
await writeFile(new URL('../src/harness/contracts/corpus-v1.json', import.meta.url), `${JSON.stringify(corpus, null, 2)}\n`);
console.log(`generated ${slots.length} snapshot/entity/event structural slots`);

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
