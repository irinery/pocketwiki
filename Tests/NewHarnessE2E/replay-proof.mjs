import { validateAgainst } from '../../src/harness/contracts/validate.mjs';
import { createHash } from 'node:crypto';

// A nonce binds artifacts to one runner invocation; it is not authentication.
export function validateReplayProof(proof, { surface, nonce }) {
  const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
  if (!proof || proof.version !== 1 || proof.level !== 'integration' || proof.surface !== surface || !['web', 'macos'].includes(surface) ||
      typeof nonce !== 'string' || !/^[a-f0-9]{32}$/.test(nonce) || proof.nonce !== nonce ||
      !Number.isSafeInteger(proof.boundary) || proof.boundary < 1 || proof.boundary >= Number.MAX_SAFE_INTEGER ||
      !Array.isArray(proof.frames) || proof.frames.length < 4) throw new Error('invalid integrated replay proof identity or boundary');
  const validCollection = (value, schema, idField) => value && typeof value === 'object' && !Array.isArray(value) &&
    Object.entries(value).every(([id, item]) => item?.[idField] === id && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id) && validateAgainst(schema, item).valid);
  const validState = (state, cursor) => state && typeof state === 'object' && !Array.isArray(state) &&
    Object.keys(state).sort().join(',') === 'effects,lastSeq,receipts,revision' &&
    Number.isSafeInteger(state.revision) && state.revision >= 0 && state.lastSeq === cursor &&
    validCollection(state.receipts, 'RuntimeReceipt', 'command_id') &&
    Object.values(state.receipts).every(receipt => Number.isSafeInteger(receipt.revision) && receipt.revision >= 0 && receipt.revision <= state.revision) &&
    validCollection(state.effects, 'EffectRecord', 'effect_id');
  const boundary = proof.boundary;
  for (let i = 0; i < 4; i++) {
    const frame = proof.frames[i];
    if (!frame || frame.seq !== (i < 3 ? boundary - 1 + i : boundary + 1) || !hash(frame.before) || !hash(frame.after) ||
        !frame.event || !validateAgainst('streamEnvelope', frame.event).valid || frame.event.module !== 'runtime' ||
        frame.event.seq !== frame.seq || frame.event.event_id !== frame.event_id || !hash(frame.event_sha256) ||
        replayProofSHA256(Buffer.from(canonicalJSON(frame.event))) !== frame.event_sha256 ||
        (i > 0 && (frame.event.thread_id !== proof.frames[0].event.thread_id || frame.event.environment_id !== proof.frames[0].event.environment_id)) ||
        frame.before_cursor !== (i < 3 ? boundary : boundary + 1) || frame.after_cursor !== (i < 2 ? boundary : boundary + 1) ||
        !validState(frame.before_state, frame.before_cursor) || !validState(frame.after_state, frame.after_cursor) ||
        frame.after_state.revision < frame.before_state.revision ||
        replayProofSHA256(Buffer.from(canonicalJSON(frame.before_state))) !== frame.before ||
        replayProofSHA256(Buffer.from(canonicalJSON(frame.after_state))) !== frame.after ||
        (i > 0 && frame.before !== proof.frames[i - 1].after) ||
        (i === 2 ? frame.before === frame.after : frame.before !== frame.after)) {
      throw new Error('invalid integrated replay frames or projection changes');
    }
  }
  const snapshot = proof.snapshot;
  if (!snapshot || !hash(proof.snapshot_sha256) || replayProofSHA256(Buffer.from(canonicalJSON(snapshot))) !== proof.snapshot_sha256 ||
      !validateAgainst('snapshotEnvelope', snapshot.envelope).valid || snapshot.envelope.module !== 'runtime' ||
      snapshot.envelope.data.as_of_seq !== boundary || snapshot.envelope.data.next_cursor != null ||
      snapshot.thread_id !== proof.frames[0]?.event?.thread_id ||
      proof.frames.slice(0, 4).some(frame => frame.snapshot_id !== snapshot.envelope.data.snapshot_id)) throw new Error('invalid UI snapshot evidence');
  const data = snapshot.envelope.data;
  const initial = { revision: data.revision, lastSeq: boundary,
    receipts: Object.fromEntries(data.receipts.map(item => [item.command_id, item])),
    effects: Object.fromEntries(data.effects.map(item => [item.effect_id, item])) };
  if (Object.keys(initial.receipts).length !== data.receipts.length || Object.keys(initial.effects).length !== data.effects.length ||
      canonicalJSON(initial) !== canonicalJSON(proof.frames[0].before_state)) throw new Error('UI snapshot does not match initial projection');
  const event = proof.frames[2], replay = proof.frames[3];
  if (typeof event.event_id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(event.event_id) ||
      event.event_id !== replay.event_id || !hash(event.event_sha256) || event.event_sha256 !== replay.event_sha256 ||
      event.event.event_id !== event.event_id || replay.event.event_id !== replay.event_id) {
    throw new Error('invalid duplicate replay event identity');
  }
  return proof;
}

export function replayProofSHA256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function canonicalJSON(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonicalJSON).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonicalJSON(value[key])).join(',') + '}';
}
