import test from 'node:test';
import assert from 'node:assert/strict';
import { validateReplayProof, replayProofSHA256, canonicalJSON } from './replay-proof.mjs';
const nonce = 'a'.repeat(32);
const state = seq => ({ revision: 1, lastSeq: seq, receipts: {}, effects: {} });
const digest = value => replayProofSHA256(Buffer.from(canonicalJSON(value)));
const envelope = seq => ({ protocol_major: 1, event_id: '00000000-0000-4000-8000-000000000001', environment_id: '00000000-0000-4000-8000-000000000002', thread_id: '00000000-0000-4000-8000-000000000002', seq, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { entity_type: 'RuntimeEvent', entity_key: JSON.stringify('00000000-0000-4000-8000-000000000001'), change: 'upsert', value: { event_id: '00000000-0000-4000-8000-000000000001', thread_id: '00000000-0000-4000-8000-000000000002', seq, kind: 'intent_committed' } } });
const frame = (seq, before, after) => ({ seq, snapshot_id: '00000000-0000-4000-8000-000000000003', before_cursor: before, after_cursor: after, before_state: state(before), after_state: state(after), before: digest(state(before)), after: digest(state(after)), event_id: '00000000-0000-4000-8000-000000000001', event: envelope(seq), event_sha256: digest(envelope(seq)) });
const sample = (boundary = 10) => {
  const snapshot = { thread_id: '00000000-0000-4000-8000-000000000002', envelope: { module: 'runtime', data: { snapshot_id: '00000000-0000-4000-8000-000000000003', revision: 1, as_of_seq: boundary, receipts: [], effects: [] } } };
  return { version: 1, level: 'integration', surface: 'web', nonce, boundary, snapshot, snapshot_sha256: digest(snapshot), frames: [frame(boundary - 1, boundary, boundary), frame(boundary, boundary, boundary), frame(boundary + 1, boundary, boundary + 1), frame(boundary + 1, boundary + 1, boundary + 1)] };
};
test('accepts dynamic boundaries and rejects invalid or incomplete integration evidence', () => {
  assert.doesNotThrow(() => validateReplayProof(sample(), { surface: 'web', nonce }));
  assert.doesNotThrow(() => validateReplayProof(sample(9), { surface: 'web', nonce }));
  assert.doesNotThrow(() => validateReplayProof(sample(1), { surface: 'web', nonce }));
  for (const bad of [undefined, { ...sample(), boundary: 0 }, { ...sample(), boundary: Number.MAX_SAFE_INTEGER }, { ...sample(), boundary: 9 }, { ...sample(), level: 'unit' }, { ...sample(), nonce: '0'.repeat(32) }, { ...sample(), frames: sample().frames.slice(1) }, { ...sample(), frames: [frame(9, 10, 11), ...sample().frames.slice(1)] }, { ...sample(), frames: [...sample().frames.slice(0, 2), frame(11, 10, 10), frame(11, 11, 11)] }, { ...sample(), frames: sample().frames.slice(0, 3) }, { ...sample(), frames: [...sample().frames.slice(0, 3), { ...sample().frames[3], event_sha256: 'f'.repeat(64) }] }]) {
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
    assert.throws(() => validateReplayProof(proof, { surface: 'web', nonce }), /invalid (integrated replay frames|UI snapshot)/);
  }
});

test('rejects regressive view revisions and receipts newer than the view', () => {
  const regressive = sample();
  regressive.frames[2].after_state.revision = 0;
  regressive.frames[2].after = digest(regressive.frames[2].after_state);
  assert.throws(() => validateReplayProof(regressive, { surface: 'web', nonce }), /invalid integrated replay frames/);
  const ahead = sample();
  const id = '00000000-0000-4000-8000-000000000001';
  const receipt = { command_id: id, receipt_id: id, payload_sha256: 'a'.repeat(64), revision: 2, state: 'accepted' };
  for (const item of ahead.frames) {
    item.before_state.receipts[id] = receipt; item.after_state.receipts[id] = receipt;
    item.before = digest(item.before_state); item.after = digest(item.after_state);
  }
  assert.throws(() => validateReplayProof(ahead, { surface: 'web', nonce }), /invalid integrated replay frames/);
});


test('rejects a replayed envelope whose payload or identity differs', () => {
  const different = sample(9);
  different.frames[3].event.payload.value.kind = 'effect_started';
  different.frames[3].event_sha256 = digest(different.frames[3].event);
  assert.throws(() => validateReplayProof(different, { surface: 'web', nonce }), /invalid duplicate replay event identity/);
  const tampered = sample(9);
  tampered.frames[3].event.seq = 99;
  assert.throws(() => validateReplayProof(tampered, { surface: 'web', nonce }), /invalid integrated replay frames/);
  const wrongAggregate = sample(9);
  wrongAggregate.frames[0].event.thread_id = '00000000-0000-4000-8000-000000000003';
  wrongAggregate.frames[0].event_sha256 = digest(wrongAggregate.frames[0].event);
  assert.throws(() => validateReplayProof(wrongAggregate, { surface: 'web', nonce }), /invalid integrated replay frames/);
});

test('binds the snapshot observed by the UI to the boundary and projection', () => {
  const missing = sample(9); delete missing.snapshot;
  assert.throws(() => validateReplayProof(missing, { surface: 'web', nonce }), /invalid UI snapshot/);
  const wrongBoundary = sample(9); wrongBoundary.snapshot.envelope.data.as_of_seq = 10;
  wrongBoundary.snapshot_sha256 = digest(wrongBoundary.snapshot);
  assert.throws(() => validateReplayProof(wrongBoundary, { surface: 'web', nonce }), /invalid UI snapshot/);
  const wrongState = sample(9); wrongState.snapshot.envelope.data.revision = 2;
  wrongState.snapshot_sha256 = digest(wrongState.snapshot);
  assert.throws(() => validateReplayProof(wrongState, { surface: 'web', nonce }), /UI snapshot does not match/);
  const wrongSnapshot = sample(9); wrongSnapshot.frames[2].snapshot_id = '00000000-0000-4000-8000-000000000004';
  assert.throws(() => validateReplayProof(wrongSnapshot, { surface: 'web', nonce }), /invalid UI snapshot/);
});

test('validates RuntimeEvent, EffectRecord and RuntimeReceipt transitions', () => {
  const id = '00000000-0000-4000-8000-000000000001';
  const owner = '00000000-0000-4000-8000-000000000002';
  const effect = { effect_id: id, command_id: owner, state: 'succeeded' };
  const receipt = { command_id: id, receipt_id: id, payload_sha256: 'a'.repeat(64), revision: 2, state: 'accepted' };
  for (const [type, change, value] of [
    ['EffectRecord', 'upsert', effect], ['EffectRecord', 'delete', effect],
    ['RuntimeReceipt', 'upsert', receipt], ['RuntimeReceipt', 'delete', { ...receipt, revision: 1 }]
  ]) {
    const proof = sample(9), field = type === 'EffectRecord' ? 'effects' : 'receipts';
    if (change === 'delete') {
      proof.snapshot.envelope.data[field] = [value];
      for (const item of proof.frames) { item.before_state[field][id] = value; item.after_state[field][id] = value; }
    }
    const payload = { entity_type: type, entity_key: JSON.stringify(id), change, ...(change === 'upsert' ? { value } : {}) };
    for (const item of proof.frames.slice(2)) { item.event.payload = payload; item.event_sha256 = digest(item.event); }
    if (change === 'upsert') {
      proof.frames[2].after_state[field][id] = value;
      proof.frames[3].before_state[field][id] = value;
      proof.frames[3].after_state[field][id] = value;
      if (type === 'RuntimeReceipt') for (const item of [proof.frames[2].after_state, proof.frames[3].before_state, proof.frames[3].after_state]) item.revision = 2;
    } else {
      delete proof.frames[2].after_state[field][id];
      delete proof.frames[3].before_state[field][id];
      delete proof.frames[3].after_state[field][id];
    }
    proof.snapshot_sha256 = digest(proof.snapshot);
    for (const item of proof.frames) { item.before = digest(item.before_state); item.after = digest(item.after_state); }
    assert.doesNotThrow(() => validateReplayProof(proof, { surface: 'web', nonce }), `${type} ${change}`);
    if (change === 'upsert') {
      const discarded = structuredClone(proof);
      delete discarded.frames[2].after_state[field][id];
      delete discarded.frames[3].before_state[field][id];
      delete discarded.frames[3].after_state[field][id];
      for (const item of discarded.frames) { item.before = digest(item.before_state); item.after = digest(item.after_state); }
      assert.throws(() => validateReplayProof(discarded, { surface: 'web', nonce }), /replay payload does not match/);
    }
  }
  assert.doesNotThrow(() => validateReplayProof(sample(9), { surface: 'web', nonce }), 'RuntimeEvent advances only cursor');
});
