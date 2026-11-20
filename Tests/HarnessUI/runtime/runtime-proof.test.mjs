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
test('captura precisa ser PNG de tamanho limitado', async () => {
  const { requireRuntimeScreenshot } = await import('./runtime-proof.mjs');
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
  assert.doesNotThrow(() => requireRuntimeScreenshot(png));
  assert.throws(() => requireRuntimeScreenshot(Buffer.alloc(24)));
  const oversized = Buffer.from(png); oversized.writeUInt32BE(2000, 20);
  assert.throws(() => requireRuntimeScreenshot(oversized));
  assert.doesNotThrow(() => requireRuntimeScreenshot(oversized, { maxHeight: 2048 }));
  assert.throws(() => requireRuntimeScreenshot(png, { maxHeight: 2049 }));
  const textChunk = Buffer.from([0, 0, 0, 0, 116, 69, 88, 116, 0, 0, 0, 0]);
  assert.throws(() => requireRuntimeScreenshot(Buffer.concat([png.subarray(0, -12), textChunk, png.subarray(-12)])));
});
