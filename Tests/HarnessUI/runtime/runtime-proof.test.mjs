import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requireRuntimeProof } from './runtime-proof.mjs';
const expected = { nonce: 'nonce-atual', pocketwikiSHA: 'a'.repeat(40) };
const valid = { nonce: expected.nonce, pocketwiki_sha: expected.pocketwikiSHA, runtime_fallback_verified: true, legacy_capability_status: 404, skipped_tests: 0 };
test('prova nativa deve corresponder ao run, ao SHA e às asserções', () => {
  assert.doesNotThrow(() => requireRuntimeProof(valid, expected));
  for (const bad of [null, {}, { ...valid, nonce: 'antigo' }, { ...valid, pocketwiki_sha: 'b'.repeat(40) }, { ...valid, runtime_fallback_verified: false }, { ...valid, legacy_capability_status: 200 }, { ...valid, skipped_tests: 1 }, { ...valid, extra: true }]) {
    assert.throws(() => requireRuntimeProof(bad, expected));
  }
});
