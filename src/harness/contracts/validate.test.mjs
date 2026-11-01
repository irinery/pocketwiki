import test from 'node:test';
import assert from 'node:assert/strict';
import corpus from './corpus-v1.json' with { type: 'json' };
import { operationRegistry, listCapabilities } from '../registry.mjs';
import { validateAgainst, validateCommandEnvelope } from './validate.mjs';

test('shared NH-00 corpus matches expected acceptance in JavaScript', () => {
  for (const slot of corpus.slots) {
    const result = validateAgainst(slot.schema, slot.value);
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
});
