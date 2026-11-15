import test from 'node:test';
import assert from 'node:assert/strict';
import { validateReplayProof, replayProofSHA256, canonicalJSON } from './replay-proof.mjs';
const nonce = 'a'.repeat(32);
const state = seq => ({ revision: 1, lastSeq: seq, receipts: {}, effects: {} });
const digest = value => replayProofSHA256(Buffer.from(canonicalJSON(value)));
const frame = (seq, before, after) => ({ seq, before_cursor: before, after_cursor: after, before_state: state(before), after_state: state(after), before: digest(state(before)), after: digest(state(after)) });
const sample = () => ({ version: 1, level: 'integration', surface: 'web', nonce, boundary: 10, frames: [frame(9, 10, 10), frame(10, 10, 10), frame(11, 10, 11)] });
test('accepts literal integration replay and rejects absent, B9, unit and malformed evidence', () => {
  assert.doesNotThrow(() => validateReplayProof(sample(), { surface: 'web', nonce }));
  for (const bad of [undefined, { ...sample(), boundary: 9 }, { ...sample(), level: 'unit' }, { ...sample(), nonce: '0'.repeat(32) }, { ...sample(), frames: sample().frames.slice(1) }, { ...sample(), frames: [frame(9, 10, 11), ...sample().frames.slice(1)] }, { ...sample(), frames: [...sample().frames.slice(0, 2), frame(11, 10, 10)] }]) {
    assert.throws(() => validateReplayProof(bad, { surface: 'web', nonce }));
  }
  assert.throws(() => validateReplayProof(sample(), { surface: 'macos', nonce }));
  assert.equal(replayProofSHA256(Buffer.from('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('rejects malformed materialized records even with matching recomputed hashes', () => {
  for (const invalid of [[], { bad: {} }, { '00000000-0000-4000-8000-000000000001': { command_id: '00000000-0000-4000-8000-000000000002' } }]) {
    const proof = sample();
    for (const item of proof.frames) {
      item.before_state.receipts = invalid;
      item.after_state.receipts = invalid;
      item.before = digest(item.before_state);
      item.after = digest(item.after_state);
    }
    assert.throws(() => validateReplayProof(proof, { surface: 'web', nonce }), /invalid integrated replay frames/);
  }
});
