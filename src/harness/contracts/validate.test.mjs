import test from 'node:test';
import assert from 'node:assert/strict';
import corpus from './corpus-v1.json' with { type: 'json' };
import schema from './harness-v1.schema.json' with { type: 'json' };
import { operationRegistry, listCapabilities, requireOperation } from '../registry.mjs';
import { validateAgainst, validateCommandEnvelope, validateOperationInput } from './validate.mjs';

test('shared NH-00 corpus matches expected acceptance in JavaScript', () => {
  for (const slot of corpus.slots) {
    const result = validateAgainst(slot.schema, slot.value, slot.operation);
    assert.equal(result.valid, slot.accept, `${slot.id}: ${result.errors.join('; ')}`);
  }
});

test('commands require a registered mutation and preserve the closed envelope', () => {
  const valid = corpus.slots.find(({ id }) => id === 'NH00-ENV-001').value;
  assert.equal(validateCommandEnvelope(valid, operationRegistry).valid, true);
  assert.equal(validateCommandEnvelope({ ...valid, user_id: 'caller-controlled' }, operationRegistry).valid, false);
  assert.equal(validateCommandEnvelope({ ...valid, operation: 'providers.catalog' }, operationRegistry).valid, false);
  assert.equal(validateCommandEnvelope({ ...valid, operation: 'made.up' }, operationRegistry).valid, false);
});

test('capabilities expose only implemented operations', () => {
  assert.deepEqual(listCapabilities(), []);
  assert.ok(operationRegistry.length >= 40);
  assert.ok(operationRegistry.every(({ owner, test_slot, class: operationClass }) => owner && test_slot && ['read', 'mutation', 'bootstrap', 'local'].includes(operationClass)));
  assert.equal(operationRegistry.find(({ name }) => name === 'workspaces.settings').class, 'mutation');
  assert.equal(operationRegistry.find(({ name }) => name === 'memory.map_legacy').class, 'mutation');
  assert.equal(operationRegistry.find(({ name }) => name === 'diagnostics.export').class, 'mutation');
});

test('future operations and unknown protocol versions remain unavailable', () => {
  assert.ok(operationRegistry.every(({ implemented }) => implemented === false));
  for (const name of ['threads.history', 'mcp.thread.call', 'source_control.execute']) {
    assert.throws(() => requireOperation(name, operationRegistry.find((entry) => entry.name === name).class), { code: 'ERR_UNSUPPORTED' });
  }
  assert.throws(() => requireOperation('runtime.dispatch', 'read'), { code: 'ERR_INVALID' });
  assert.throws(() => requireOperation('runtime.receipt', 'mutation'), { code: 'ERR_INVALID' });
  const command = corpus.slots.find(({ id }) => id === 'NH00-ENV-001').value;
  assert.equal(validateAgainst('command', { ...command, protocol_major: 2 }).valid, false);
  assert.ok(operationRegistry.every(({ input_schema }) => Boolean(schema.$defs[input_schema])), 'future operation schemas remain defined');
});

test('shared operation corpus covers every registered operation and its validator path', () => {
  for (const operation of operationRegistry) {
    const slots = corpus.slots.filter(({ id }) => id.startsWith(`${operation.test_slot}-`));
    assert.ok(slots.some(({ accept }) => accept), `${operation.name} has no valid corpus case`);
    assert.ok(slots.some(({ accept }) => !accept), `${operation.name} has no invalid corpus case`);
    assert.ok(slots.some(({ id }) => id.endsWith('-CLOSED')), `${operation.name} has no closed-object case`);
    assert.ok(slots.some(({ id }) => id.includes('-TYPE-')), `${operation.name} has no invalid-type case`);
    const inputSchema = schema.$defs[operation.input_schema];
    const primary = inputSchema.oneOf?.[0] ?? inputSchema;
    for (const required of primary.required ?? []) {
      assert.ok(slots.some(({ id }) => id.endsWith(`-REQUIRED-${required}`)), `${operation.name}.${required} has no missing-required case`);
    }
    assert.ok(operation.input_fields.every(({ validation }) => typeof validation === 'string' && validation.length > 0), `${operation.name} has an undocumented input condition`);
    const valid = slots.find(({ id }) => id.endsWith('-VALID'));
    assert.equal(validateOperationInput(operation.name, valid.value).valid, true, `${valid.id}`);
  }
});

test('all 15 snapshots, referenced entities, and module event variants have valid and nested closed cases', () => {
  const snapshots = schema.$defs.snapshotEnvelope.oneOf;
  assert.equal(snapshots.length, 15);
  for (const variant of snapshots) {
    const module = variant.properties.module.const;
    const snapshot = schema.$defs[variant.properties.data.$ref.slice('#/$defs/'.length)];
    assert.ok(corpus.slots.some(({ id, accept }) => id === `NH00-STRUCT-SNAPSHOT-${module}-CURSOR-ABSENT` && accept), `${module} permits an absent next_cursor`);
    assert.ok(corpus.slots.some(({ id, accept }) => id === `NH00-STRUCT-SNAPSHOT-${module}-CURSOR-NULL` && !accept), `${module} rejects next_cursor null`);
    const entities = Object.entries(snapshot.properties ?? {}).flatMap(([field, rule]) => {
      const ref = rule.type === 'array' ? rule.items?.$ref : rule.$ref;
      const name = ref?.slice('#/$defs/'.length);
      return name && schema.$defs[name]?.type === 'object' ? [[field, name, rule.type === 'array']] : [];
    });
    for (const [field, , isCollection] of entities) {
      if (isCollection) continue;
      if (!snapshot.required?.includes(field)) continue;
      assert.ok(corpus.slots.some(({ id, accept }) => id === `NH00-STRUCT-SNAPSHOT-${module}-${field}-SINGLETON-MISSING` && !accept), `${module}.${field} required singleton has no missing case`);
    }
    for (const [, entity] of entities) {
      const prefix = `NH00-STRUCT-SNAPSHOT-${module}-${entity}-`;
      assert.ok(corpus.slots.some(({ id, accept }) => id === `${prefix}VALID` && accept), `${module}.${entity} has no nested valid case`);
      assert.ok(corpus.slots.some(({ id, accept }) => id === `${prefix}NESTED-EXTRA` && !accept), `${module}.${entity} has no nested closed case`);
    }
  }
  const inlineEvents = schema.$defs.streamEnvelope.oneOf.filter(({ properties }) => properties.delivery?.const === 'inline');
  let variantCount = 0;
  for (const event of inlineEvents) {
    const module = event.properties.module.const;
    const eventSchema = schema.$defs[event.properties.payload.$ref.slice('#/$defs/'.length)];
    for (const variant of eventSchema.oneOf ?? []) {
      variantCount++;
      const entity = variant.properties.entity_type.const;
      const change = variant.properties.change.const;
      const prefix = `NH00-STRUCT-EVENT-${module}-${entity}-${change}-`;
      assert.ok(corpus.slots.some(({ id, accept }) => id === `${prefix}VALID` && accept), `${module}.${entity} event has no valid case`);
      assert.ok(corpus.slots.some(({ id, accept }) => id === `${prefix}CLOSED` && !accept), `${module}.${entity} event has no closed case`);
    }
  }
  assert.ok(variantCount > 40);
});

test('optional and nullable are independent', () => {
  const optionalButNotNullable = corpus.slots.find(({ id }) => id === 'NH00-AUTH-001');
  const explicitNull = corpus.slots.find(({ id }) => id === 'NH00-AUTH-003');
  const nullable = corpus.slots.find(({ id }) => id === 'NH00-ENV-011');
  assert.equal(validateAgainst(optionalButNotNullable.schema, optionalButNotNullable.value).valid, true);
  assert.equal(validateAgainst(explicitNull.schema, explicitNull.value).valid, false);
  assert.equal(validateAgainst(nullable.schema, nullable.value).valid, true);
});

test('permission action discriminators reject fields from other variants and mismatched request metadata', () => {
  for (const id of ['NH00-PERM-002', 'NH00-PERM-003', 'NH00-PERM-005', 'NH00-PREQ-002', 'NH00-PREQ-003']) {
    const slot = corpus.slots.find((entry) => entry.id === id);
    assert.equal(validateAgainst(slot.schema, slot.value).valid, false, id);
  }
});
