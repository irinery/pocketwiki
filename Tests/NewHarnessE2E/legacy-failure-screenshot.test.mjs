import test from 'node:test';
import assert from 'node:assert/strict';
import { legacyFailureScreenshotPayload } from './MacOSHost/legacy-failure-screenshot.mjs';

test('exports only a single retained screenshot of the named legacy fixture', () => {
  const fixture = { name: 'nh-legacy-fixture-failure_0_DA85B5FF-85F9-4D39-AD1E-7E9D3309F51C.png', payloadId: '0~Abcdefghijklmnop==', lifetime: 'keepAlways' };
  const desktop = { ...fixture, name: 'desktop.png' };
  assert.equal(legacyFailureScreenshotPayload({ testRuns: [{ activities: [{ attachments: [desktop, fixture] }] }] }), fixture.payloadId);
  assert.equal(legacyFailureScreenshotPayload({ activities: [{ attachments: [fixture] }], attachments: [fixture] }), fixture.payloadId);
  for (const attachments of [[], [desktop], [fixture, { ...fixture, payloadId: '0~DifferentValidPayload' }], [fixture, { ...fixture, uuid: 'different' }], [{ ...fixture, lifetime: 'deleteOnSuccess' }], [{ ...fixture, payloadId: '0~../invalid' }]]) {
    assert.throws(() => legacyFailureScreenshotPayload({ attachments }), /unavailable or ambiguous/);
  }
});
