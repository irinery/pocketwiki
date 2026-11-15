import { createHash, timingSafeEqual } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import path from 'node:path';

// This is a non-wire proposal validator, not a recovery executor or an ACL.
// Kernel/host integration must provide the authoritative receipt and guard.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const HASH = /^[0-9a-f]{64}$/;
const MAX_PAYLOAD = 16 * 1024 * 1024;
const REQUIRED = ['journal_version', 'command_id', 'receipt_id', 'principal_id', 'environment_id',
  'operation', 'scopes', 'command_sha256', 'payload_sha256', 'payload_base64'];
const ALLOWED = new Set([...REQUIRED, 'project_id', 'thread_id']);
const OPERATIONS = new Set(['memory.capture_scoped', 'memory.note.put', 'memory.map_legacy', 'memory.import']);

/**
 * Validate proposed journal metadata and payload integrity without recovering it.
 * Even a valid envelope stays blocked: ids and hashes are not authority.
 * The return value intentionally contains no identity, payload, or credential.
 */
export function inspectRecoveryEnvelope(value) {
  const blocked = (code) => ({ status:'blocked', code });
  if (!value || typeof value !== 'object' || Array.isArray(value)) return blocked('ERR_INVALID');
  if (!Object.hasOwn(value, 'journal_version')) return blocked('ERR_INCOMPATIBLE');
  if (value.journal_version !== 1) return blocked('ERR_INCOMPATIBLE');
  if (Object.keys(value).some((key) => !ALLOWED.has(key)) || REQUIRED.some((key) => !Object.hasOwn(value, key))) {
    return blocked('ERR_INVALID');
  }
  if (!['command_id', 'receipt_id', 'principal_id', 'environment_id'].every((key) => UUID.test(value[key] || '')) ||
      (!value.project_id && !value.thread_id) ||
      (value.project_id !== undefined && !UUID.test(value.project_id)) ||
      (value.thread_id !== undefined && !UUID.test(value.thread_id)) ||
      !OPERATIONS.has(value.operation) || !Array.isArray(value.scopes) ||
      value.scopes.length !== 1 || value.scopes[0] !== 'memory.write' ||
      !HASH.test(value.command_sha256 || '') || !HASH.test(value.payload_sha256 || '') ||
      typeof value.payload_base64 !== 'string' || value.payload_base64.length > Math.ceil(MAX_PAYLOAD / 3) * 4 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.payload_base64)) {
    return blocked('ERR_INVALID');
  }
  const payload = Buffer.from(value.payload_base64, 'base64');
  if (payload.length > MAX_PAYLOAD || payload.toString('base64') !== value.payload_base64) return blocked('ERR_INVALID');
  const actual = createHash('sha256').update(payload).digest();
  const expected = Buffer.from(value.payload_sha256, 'hex');
  if (!timingSafeEqual(actual, expected)) return blocked('ERR_INVALID');
  return blocked('ERR_UNAVAILABLE');
}

/** `directory` is host configuration, never a path supplied by a client. */
export async function inspectRecoveryFile(directory, name) {
  const blocked = (code) => ({ status:'blocked', code });
  if (typeof directory !== 'string' || !path.isAbsolute(directory) ||
      !['.capture-intent.json', '.note-intent.json', '.import-intent.json'].includes(name)) return blocked('ERR_INVALID');
  let handle;
  try {
    const parent = await lstat(directory);
    if (!parent.isDirectory() || parent.isSymbolicLink()) return blocked('ERR_FORBIDDEN');
    handle = await open(path.join(directory, name), constants.O_RDONLY | constants.O_NOFOLLOW);
    const info = await handle.stat();
    if (!info.isFile() || info.size > Math.ceil(MAX_PAYLOAD / 3) * 4 + 8192) return blocked('ERR_INVALID');
    const bytes = await handle.readFile();
    if (bytes.length > Math.ceil(MAX_PAYLOAD / 3) * 4 + 8192) return blocked('ERR_INVALID');
    let value;
    try { value = JSON.parse(bytes.toString('utf8')); }
    catch { return blocked('ERR_INVALID'); }
    return inspectRecoveryEnvelope(value);
  } catch (cause) {
    return blocked(cause.code === 'ELOOP' ? 'ERR_FORBIDDEN' : 'ERR_UNAVAILABLE');
  } finally {
    await handle?.close();
  }
}
