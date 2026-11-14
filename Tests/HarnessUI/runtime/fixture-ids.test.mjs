import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fixtureUUID } from './fixture-ids.mjs';
test('seed reproduz IDs de fixture e separa cenários', () => {
  const first = ['principal', 'environment', 'thread', 'submit'].map(label => fixtureUUID(20261102, label));
  assert.deepEqual(first, ['principal', 'environment', 'thread', 'submit'].map(label => fixtureUUID(20261102, label)));
  assert.equal(new Set(first).size, 4); assert.notEqual(first[0], fixtureUUID(20261103, 'principal'));
  for (const id of first) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
