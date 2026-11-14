import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixtureUUID } from './fixture-ids.mjs';
test('seed reproduz IDs de fixture e separa cenários', () => {
  const first = ['principal', 'environment', 'thread', 'submit'].map(label => fixtureUUID(20261102, label));
  assert.deepEqual(first, ['principal', 'environment', 'thread', 'submit'].map(label => fixtureUUID(20261102, label)));
  assert.equal(new Set(first).size, 4); assert.notEqual(first[0], fixtureUUID(20261103, 'principal'));
  for (const id of first) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
test('sequência de comandos do fixture é estável e não reutiliza IDs', () => {
  const sequence = seed => Array.from({ length: 16 }, (_, index) => fixtureUUID(seed, `web/replay/ui-command-${index}`));
  assert.deepEqual(sequence(20261102), sequence(20261102));
  assert.equal(new Set(sequence(20261102)).size, 16);
});
