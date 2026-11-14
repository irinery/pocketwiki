import { createHash } from 'node:crypto';

export const DEFAULT_FIXTURE_SEED = 20261102;

export function parseFixtureSeed(value = String(DEFAULT_FIXTURE_SEED)) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new TypeError('fixture seed deve ser inteiro não negativo');
  const seed = Number(value);
  if (!Number.isSafeInteger(seed)) throw new TypeError('fixture seed fora do intervalo seguro');
  return seed;
}

// IDs are test fixtures only; authentication and bearer generation remain cryptographic.
export function fixtureUUID(seed, label) {
  if (!Number.isSafeInteger(seed) || seed < 0 || typeof label !== 'string' || !label) throw new TypeError('seed ou rótulo de fixture inválido');
  const bytes = createHash('sha256').update('pocketwiki-e1-runtime-fixture\0').update(String(seed)).update('\0').update(label).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
