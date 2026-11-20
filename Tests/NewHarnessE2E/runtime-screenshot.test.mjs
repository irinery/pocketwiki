import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runtimeScreenshotPayload, sanitizeRuntimeScreenshot } from './MacOSHost/runtime-screenshot.mjs';
function chunk(type, payload) {
  const body = Buffer.concat([Buffer.from(type), payload]); let crc = 0xffffffff;
  for (const byte of body) { crc ^= byte; for (let n = 0; n < 8; n++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
  const length = Buffer.alloc(4), checksum = Buffer.alloc(4); length.writeUInt32BE(payload.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, body, checksum]);
}
test('fixture PNG loses textual metadata and rejects corruption or oversized input', async () => {
  const fixture = await readFile('favicon.png');
  const secret = Buffer.from('fixture-metadata-that-must-not-be-exported');
  const withMetadata = Buffer.concat([fixture.subarray(0, 33), chunk('tEXt', secret), fixture.subarray(33)]);
  const cleaned = sanitizeRuntimeScreenshot(withMetadata);
  assert.equal(cleaned.includes(secret), false);
  assert.deepEqual(cleaned, sanitizeRuntimeScreenshot(fixture));
  const damaged = Buffer.from(withMetadata); damaged[45] ^= 1;
  assert.throws(() => sanitizeRuntimeScreenshot(damaged), /checksum/);
  assert.throws(() => sanitizeRuntimeScreenshot(Buffer.alloc(8 * 1024 * 1024 + 1)), /invalid/);
  assert.throws(() => sanitizeRuntimeScreenshot(fixture.subarray(0, -3)), /truncated/);
});


test('selects exactly one named slot attachment and rejects ambiguous or unrelated images', () => {
  const slot = { name: 'nh-runtime-fallback_0_DA85B5FF-85F9-4D39-AD1E-7E9D3309F51C.png', payloadId: '0~Abcdefghijklmnop==', lifetime: 'keepAlways' };
  assert.equal(runtimeScreenshotPayload({ testRuns: [{ activities: [{ attachments: [slot] }] }] }), '0~Abcdefghijklmnop==');
  assert.throws(() => runtimeScreenshotPayload({ attachments: [] }), /ausente ou ambíguo/);
  assert.throws(() => runtimeScreenshotPayload({ attachments: [slot, slot] }), /ausente ou ambíguo/);
  assert.throws(() => runtimeScreenshotPayload({ attachments: [{ ...slot, name: 'desktop.png' }] }), /ausente ou ambíguo/);
  for (const payloadId of ['', 'bad-id', '0~../invalid']) assert.throws(() => runtimeScreenshotPayload({ attachments: [{ ...slot, payloadId }] }), /ausente ou ambíguo/);
  assert.throws(() => runtimeScreenshotPayload({ attachments: [{ ...slot, lifetime: 'deleteOnSuccess' }] }), /ausente ou ambíguo/);
});
