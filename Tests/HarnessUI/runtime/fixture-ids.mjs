import { createHash } from 'node:crypto';

// Fixture identities only. Credentials and server-generated IDs stay random.
export function fixtureUUID(seed, label) {
  if (!Number.isSafeInteger(seed) || seed < 0 || typeof label !== 'string' || !label) throw new TypeError('seed ou label inválido');
  const bytes = createHash('sha256').update(`pocketwiki-runtime-ui\0${seed}\0${label}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
