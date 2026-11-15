import { validateAgainst } from '../../src/harness/contracts/validate.mjs';
import { createHash } from 'node:crypto';

// A nonce binds artifacts to one runner invocation; it is not authentication.
export function validateReplayProof(proof, { surface, nonce }) {
  const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
  if (!proof || proof.version !== 1 || proof.level !== 'integration' || proof.surface !== surface || !['web', 'macos'].includes(surface) ||
      typeof nonce !== 'string' || !/^[a-f0-9]{32}$/.test(nonce) || proof.nonce !== nonce || proof.boundary !== 10 ||
      !Array.isArray(proof.frames) || proof.frames.length !== 3) throw new Error('invalid integrated replay proof identity or boundary');
  const validCollection = (value, schema, idField) => value && typeof value === 'object' && !Array.isArray(value) &&
    Object.entries(value).every(([id, item]) => item?.[idField] === id && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id) && validateAgainst(schema, item).valid);
  const validState = (state, cursor) => state && typeof state === 'object' && !Array.isArray(state) &&
    Object.keys(state).sort().join(',') === 'effects,lastSeq,receipts,revision' &&
    Number.isSafeInteger(state.revision) && state.revision >= 0 && state.lastSeq === cursor &&
    validCollection(state.receipts, 'RuntimeReceipt', 'command_id') &&
    Object.values(state.receipts).every(receipt => Number.isSafeInteger(receipt.revision) && receipt.revision >= 0 && receipt.revision <= state.revision) &&
    validCollection(state.effects, 'EffectRecord', 'effect_id');
  for (let i = 0; i < 3; i++) {
    const frame = proof.frames[i];
    if (!frame || frame.seq !== 9 + i || !hash(frame.before) || !hash(frame.after) ||
        frame.before_cursor !== 10 || frame.after_cursor !== (i < 2 ? 10 : 11) ||
        !validState(frame.before_state, frame.before_cursor) || !validState(frame.after_state, frame.after_cursor) ||
        frame.after_state.revision < frame.before_state.revision ||
        replayProofSHA256(Buffer.from(canonicalJSON(frame.before_state))) !== frame.before ||
        replayProofSHA256(Buffer.from(canonicalJSON(frame.after_state))) !== frame.after ||
        (i > 0 && frame.before !== proof.frames[i - 1].after) ||
        (i < 2 ? frame.before !== frame.after : frame.before === frame.after)) {
      throw new Error('invalid integrated replay frames or projection changes');
    }
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
