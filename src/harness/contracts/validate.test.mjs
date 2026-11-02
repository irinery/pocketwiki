import test from 'node:test';
import assert from 'node:assert/strict';
import corpus from './corpus-v1.json' with { type: 'json' };
import { operationRegistry, listCapabilities } from '../registry.mjs';
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

test('shared operation corpus covers every registered operation and its validator path', () => {
  for (const operation of operationRegistry) {
    const slots = corpus.slots.filter(({ id }) => id.startsWith(`${operation.test_slot}-`));
    assert.ok(slots.some(({ accept }) => accept), `${operation.name} has no valid corpus case`);
    assert.ok(slots.some(({ accept }) => !accept), `${operation.name} has no invalid corpus case`);
    const valid = slots.find(({ id }) => id.endsWith('-VALID'));
    assert.equal(validateOperationInput(operation.name, valid.value).valid, true, `${valid.id}`);
  }
});

test('optional and nullable are independent: absent optional UUID passes, explicit null fails', () => {
  const optionalButNotNullable = corpus.slots.find(({ id }) => id === 'NH00-AUTH-001');
  const explicitNull = corpus.slots.find(({ id }) => id === 'NH00-AUTH-003');
  assert.equal(validateAgainst(optionalButNotNullable.schema, optionalButNotNullable.value).valid, true);
  assert.equal(validateAgainst(explicitNull.schema, explicitNull.value).valid, false);
});

test('permission action discriminators reject fields from other variants and mismatched request metadata', () => {
  for (const id of ['NH00-PERM-002', 'NH00-PERM-003', 'NH00-PERM-005', 'NH00-PREQ-002', 'NH00-PREQ-003']) {
    const slot = corpus.slots.find((entry) => entry.id === id);
    assert.equal(validateAgainst(slot.schema, slot.value).valid, false, id);
  }
});
