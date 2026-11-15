import { createHash, randomUUID } from 'node:crypto';
import { chmodSync, constants as fsConstants, mkdirSync, openSync, readFileSync, realpathSync, renameSync, writeFileSync, closeSync, fstatSync, statSync, fsyncSync, unlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const SHA256 = /^[0-9a-f]{64}$/;
export const MIME_LIMITS = Object.freeze({
  'text/plain': 1024 * 1024,
  'text/markdown': 1024 * 1024,
  'image/png': 2 * 1024 * 1024,
  'image/jpeg': 2 * 1024 * 1024
});
const STAGING_TTL_MS = 86_400_000;
const DRAFT_TTL_MS = 86_400_000;
export const PREPARED_TTL_MS = 86_400_000;
const SNAPSHOT_TTL_MS = 600_000;

export class ComposerError extends Error {
  constructor(code, message = code, retryable = false) {
    super(message);
    this.name = 'ComposerError';
    this.code = code;
    this.correlation_id = randomUUID();
    this.retryable = retryable;
  }

  toJSON() {
    return { code: this.code, message: this.message.slice(0, 1024), correlation_id: this.correlation_id, retryable: this.retryable };
  }
}

export function fail(code, message) { throw new ComposerError(code, message); }
export function digest(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
function bytesOf(value) { return Buffer.from(value, 'utf8'); }
export function ownerKey(auth) { return `${auth.principal_id}:${auth.environment_id}:${auth.thread_id}`; }
export function isPlainObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }

export function validateAuth(auth, scope = 'context.read') {
  if (!isPlainObject(auth) || !UUID.test(auth.principal_id ?? '') || !UUID.test(auth.environment_id ?? '') || !UUID.test(auth.thread_id ?? '') || !Array.isArray(auth.scopes) || !auth.scopes.includes(scope)) {
    fail('ERR_FORBIDDEN', 'Ação não autorizada para esta identidade.');
  }
}

export function validateString(value, min, max, label) {
  if (typeof value !== 'string') fail('ERR_INVALID', `${label} inválido.`);
  const length = bytesOf(value).byteLength;
  if (length < min || length > max) fail('ERR_INVALID', `${label} fora do limite de bytes.`);
  return length;
}

export function validateReference(reference) {
  if (!isPlainObject(reference)) fail('ERR_INVALID', 'Referência inválida.');
  const allowed = new Set(['reference_id', 'kind', 'relative_path', 'message_id', 'sha256', 'size_bytes', 'trust']);
  if (Object.keys(reference).some((key) => !allowed.has(key))) fail('ERR_INVALID', 'Campo desconhecido em referência.');
  if (!UUID.test(reference.reference_id ?? '') || !['wiki', 'file', 'quote', 'image'].includes(reference.kind) || !SHA256.test(reference.sha256 ?? '') || !Number.isSafeInteger(reference.size_bytes) || reference.size_bytes < 0 || reference.trust !== 'untrusted_content') fail('ERR_INVALID', 'Referência fora do contrato.');
  if (reference.relative_path !== undefined) validateString(reference.relative_path, 1, 4096, 'Caminho relativo');
  if (reference.message_id !== undefined && !UUID.test(reference.message_id)) fail('ERR_INVALID', 'message_id inválido.');
  return reference;
}

function decodeBase64(encoded) {
  if (typeof encoded !== 'string' || encoded.length > 5_592_408 || encoded.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) fail('ERR_INVALID', 'Base64 inválido.');
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.toString('base64') !== encoded) fail('ERR_INVALID', 'Base64 não canônico.');
  return bytes;
}

function cleanState(value) {
  if (!isPlainObject(value) || value.version !== 1 || !Array.isArray(value.drafts) || !Array.isArray(value.staging) || !Array.isArray(value.prepared) || !Array.isArray(value.snapshots) || !Array.isArray(value.events) || !Array.isArray(value.counters)) fail('ERR_UNAVAILABLE', 'Estado local do composer inválido.');
  return value;
}

export class ComposerService {
  constructor({ dataDir, now = Date.now, id = randomUUID, sourceResolver = null, rootsFor = () => [], secureReaderPath = null } = {}) {
    if (typeof dataDir !== 'string' || !dataDir) fail('ERR_INVALID', 'dataDir obrigatório.');
    this.dataDir = path.resolve(dataDir);
    this.statePath = path.join(this.dataDir, 'composer-state-v1.json');
    this.now = now;
    this.id = id;
    this.sourceResolver = sourceResolver;
    this.rootsFor = rootsFor;
    this.secureReaderPath = secureReaderPath;
    this.sourceLocations = new Map();
    mkdirSync(this.dataDir, { recursive: true, mode: 0o700 });
    chmodSync(this.dataDir, 0o700);
    this.state = this.#loadState();
    this.state.sources ??= [];
    this.confirmedState = structuredClone(this.state);
  }

  _reload() {
    this.state = this.#loadState();
    this.state.sources ??= [];
    this.confirmedState = structuredClone(this.state);
  }

  #loadState() {
    try { return cleanState(JSON.parse(readFileSync(this.statePath, 'utf8'))); }
    catch (error) {
      if (error.code === 'ENOENT') return { version: 1, drafts: [], staging: [], prepared: [], snapshots: [], events: [], counters: [] };
      if (error instanceof ComposerError) throw error;
      fail('ERR_UNAVAILABLE', 'Não foi possível ler o stash local do composer.');
    }
  }

  _persist() {
    const temporary = `${this.statePath}.${this.id()}.tmp`;
    let fd;
    try {
      fd = openSync(temporary, 'wx', 0o600);
      writeFileSync(fd, JSON.stringify(this.state), 'utf8');
      fsyncSync(fd);
      closeSync(fd);
      fd = undefined;
      renameSync(temporary, this.statePath);
      this.confirmedState = structuredClone(this.state);
    } catch {
      this.state = structuredClone(this.confirmedState);
      if (fd !== undefined) closeSync(fd);
      try { unlinkSync(temporary); } catch {}
      fail('ERR_UNAVAILABLE', 'Não foi possível persistir o stash local do composer.');
    }
  }

  _collectExpired() {
    const before = JSON.stringify(this.state);
    const now = this.now();
    this.state.staging = this.state.staging.filter((item) => item.expires_at_ms > now);
    // Keep owner tombstones for idempotent unpin; discard expired context bytes.
    for (const item of this.state.prepared) {
      if (item.pins.length === 0 && item.expires_at_ms <= now) { item.segments = []; item.manifest = []; item.expired = true; }
    }
    this.state.snapshots = this.state.snapshots.filter((item) => item.expires_at_ms > now);
    this.state.drafts = this.state.drafts.filter((item) => item.expires_at_ms > now);
    if (JSON.stringify(this.state) !== before) this._persist();
  }

  #bumpEvent(auth, type, entityId) {
    const owner = ownerKey(auth);
    let counter = this.state.counters.find((item) => item.owner === owner);
    if (!counter) {
      counter = { owner, revision: 0, sequence: 0 };
      this.state.counters.push(counter);
    }
    counter.sequence += 1;
    counter.revision += 1;
    const stored = this.state.drafts.find((draft) => draft.owner === owner && draft.draft_id === entityId);
    const { owner: _owner, expires_at_ms: _expires, ...value } = stored;
    this.state.events.push({ owner, protocol_major: 1, event_id: this.id(), environment_id: auth.environment_id, thread_id: auth.thread_id, seq: counter.sequence, committed_at_ms: this.now(), module: 'composer', delivery: 'inline', payload: { entity_type: 'ComposerDraft', entity_key: canonicalJSON(entityId), change: 'upsert', value: structuredClone(value) } });
    // Events are retained while snapshots may refer to their boundary.
  }

  stage(auth, input) {
    validateAuth(auth);
    if (!isPlainObject(input) || Object.keys(input).some((key) => !['thread_id', 'filename', 'mime', 'content_base64'].includes(key))) fail('ERR_INVALID', 'Entrada de stage inválida.');
    const { thread_id, filename, mime, content_base64 } = input;
    if (!UUID.test(thread_id ?? '')) fail('ERR_INVALID', 'thread_id inválido.');
    if (thread_id !== auth.thread_id) fail('ERR_FORBIDDEN', 'Thread não autorizada.');
    const filenameBytes = validateString(filename, 1, 255, 'Nome do arquivo');
    if (filename === '.' || filename === '..' || /[\\/\u0000-\u001f\u007f]/.test(filename) || path.basename(filename) !== filename) fail('ERR_INVALID', 'O nome precisa ser um basename simples.');
    if (!Object.hasOwn(MIME_LIMITS, mime)) fail('ERR_UNSUPPORTED', 'MIME não aceito para staging.');
    const bytes = decodeBase64(content_base64);
    if (bytes.byteLength > MIME_LIMITS[mime]) fail('ERR_INVALID', 'Anexo excede o limite do MIME.');
    this._collectExpired();
    const used = this.state.staging.filter((item) => item.owner === ownerKey(auth)).reduce((sum, item) => sum + item.reference.size_bytes, 0);
    if (used + bytes.byteLength > 4 * 1024 * 1024) fail('ERR_BUDGET', 'Staging excede 4 MiB.');
    const kind = mime.startsWith('image/') ? 'image' : 'file';
    const reference = { reference_id: this.id(), kind, sha256: digest(bytes), size_bytes: bytes.byteLength, trust: 'untrusted_content' };
    this.state.staging.push({ owner: ownerKey(auth), filename, filename_bytes: filenameBytes, mime, reference, content_base64, created_at_ms: this.now(), expires_at_ms: this.now() + STAGING_TTL_MS });
    this._persist();
    return { reference };
  }

  saveDraft(auth, draft) {
    validateAuth(auth, 'context.read');
    if (!isPlainObject(draft) || Object.keys(draft).some((key) => !['draft_id', 'thread_id', 'text', 'references', 'revision'].includes(key))) fail('ERR_INVALID', 'Draft inválido.');
    if (!UUID.test(draft.draft_id ?? '') || draft.thread_id !== auth.thread_id || !Number.isSafeInteger(draft.revision) || draft.revision < 0) fail('ERR_INVALID', 'Identidade ou revisão do draft inválida.');
    validateString(draft.text, 0, 32768, 'Texto do draft');
    if (!Array.isArray(draft.references) || draft.references.length > 20) fail('ERR_INVALID', 'Lista de referências fora do limite.');
    draft.references.forEach(validateReference);
    const duplicateIds = new Set();
    for (const reference of draft.references) {
      if (duplicateIds.has(reference.reference_id)) fail('ERR_INVALID', 'Referência duplicada.');
      duplicateIds.add(reference.reference_id);
    }
    this._collectExpired();
    const key = ownerKey(auth);
    const existing = this.state.drafts.find((item) => item.owner === key && item.draft_id === draft.draft_id);
    if ((existing?.revision ?? 0) !== draft.revision) fail('ERR_CONTEXT_STALE', 'A revisão do draft mudou.');
    const revision = draft.revision + 1;
    const stored = { owner: key, draft_id: draft.draft_id, thread_id: auth.thread_id, text: draft.text, references: structuredClone(draft.references), revision, expires_at_ms: this.now() + DRAFT_TTL_MS };
    if (existing) this.state.drafts.splice(this.state.drafts.indexOf(existing), 1, stored);
    else this.state.drafts.push(stored);
    this.#bumpEvent(auth, 'draft.saved', draft.draft_id);
    this._persist();
    return { draft_id: draft.draft_id, revision };
  }

  getDraft(auth, draftId) {
    validateAuth(auth);
    if (!UUID.test(draftId ?? '')) fail('ERR_INVALID', 'draft_id inválido.');
    this._collectExpired();
    const found = this.state.drafts.find((item) => item.owner === ownerKey(auth) && item.draft_id === draftId);
    if (!found) fail('ERR_CONTEXT_STALE', 'Draft indisponível ou expirado.');
    const { owner, expires_at_ms, ...draft } = found;
    return structuredClone(draft);
  }

  snapshot(auth, { cursor, page_size = 100 } = {}) {
    validateAuth(auth);
    if (!Number.isSafeInteger(page_size) || page_size < 1 || page_size > 100) fail('ERR_INVALID', 'page_size fora do limite.');
    this._collectExpired();
    const owner = ownerKey(auth);
    let snapshot;
    let offset = 0;
    if (cursor !== undefined) {
      if (typeof cursor !== 'string' || !UUID.test(cursor)) fail('ERR_INVALID', 'Cursor inválido.');
      snapshot = this.state.snapshots.find((item) => item.owner === owner && item.cursors[cursor] !== undefined);
      if (!snapshot) fail('ERR_CURSOR_EXPIRED', 'Snapshot expirado ou cursor de outra identidade.');
      offset = snapshot.cursors[cursor];
    } else {
      const drafts = this.state.drafts.filter((item) => item.owner === owner).sort((a, b) => a.draft_id.localeCompare(b.draft_id)).map(({ owner: _owner, expires_at_ms: _expires, ...draft }) => structuredClone(draft));
      const counter = this.state.counters.find((item) => item.owner === owner) ?? { revision: 0, sequence: 0 };
      snapshot = { snapshot_id: this.id(), owner, revision: counter.revision, as_of_seq: counter.sequence, expires_at_ms: this.now() + SNAPSHOT_TTL_MS, page_size, drafts, cursors: {} };
      this.state.snapshots.push(snapshot);
    }
    if (snapshot.page_size !== page_size) fail('ERR_INVALID', 'page_size mudou durante a paginação.');
    const drafts = [];
    // Reserve space for envelope and cursor; never split an entity.
    let pageBytes = 1024;
    for (const draft of snapshot.drafts.slice(offset, offset + page_size)) {
      const entityBytes = Buffer.byteLength(JSON.stringify(draft)) + 1;
      if (pageBytes + entityBytes > 4 * 1024 * 1024) break;
      drafts.push(draft);
      pageBytes += entityBytes;
    }
    if (!drafts.length && offset < snapshot.drafts.length) fail('ERR_INVALID', 'Entidade excede o limite da página.');
    let next_cursor;
    if (offset + drafts.length < snapshot.drafts.length) {
      next_cursor = this.id();
      snapshot.cursors[next_cursor] = offset + drafts.length;
    }
    this._persist();
    return { snapshot_id: snapshot.snapshot_id, revision: snapshot.revision, as_of_seq: snapshot.as_of_seq, drafts, ...(next_cursor ? { next_cursor } : {}) };
  }

  eventsSince(auth, afterSeq) {
    validateAuth(auth);
    if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) fail('ERR_INVALID', 'after_seq inválido.');
    return this.state.events.filter((event) => event.owner === ownerKey(auth) && event.seq > afterSeq).map(({ owner: _owner, ...event }) => structuredClone(event));
  }

  async previewFile(auth, { root, relative_path, kind = 'file' }) {
    validateAuth(auth);
    validateString(relative_path, 1, 4096, 'Caminho relativo');
    if (!['file', 'wiki', 'quote'].includes(kind) || path.isAbsolute(relative_path)) fail('ERR_INVALID', 'Fonte de arquivo inválida.');
    const approvedRoot = this.authorizeRoot(auth, root);
    const bytes = await readAuthorizedFile(approvedRoot, relative_path, this.secureReaderPath);
    const text = bytes.toString('utf8');
    if (!Buffer.from(text, 'utf8').equals(bytes)) fail('ERR_UNSUPPORTED', 'A fonte não é UTF-8 válido.');
    const reference = { reference_id: this.id(), kind, relative_path: path.posix.normalize(relative_path.split(path.sep).join('/')), sha256: digest(bytes), size_bytes: bytes.byteLength, trust: 'untrusted_content' };
    this.state.sources.push({ owner: ownerKey(auth), reference_id: reference.reference_id, root: path.resolve(root) });
    this._persist();
    return { reference };
  }

  authorizeRoot(auth, root) {
    let target;
    try { target = realpathSync(root); } catch { fail('ERR_PATH_ESCAPE', 'Root indisponível.'); }
    const roots = this.rootsFor(structuredClone(auth));
    if (!Array.isArray(roots) || !roots.some((grant) => {
      try { const canonical = realpathSync(grant); return target === canonical || target.startsWith(`${canonical}${path.sep}`); } catch { return false; }
    })) fail('ERR_FORBIDDEN', 'Root não concedido.');
    return target;
  }

  removeReference(auth, draftId, referenceId, expectedRevision) {
    const draft = this.getDraft(auth, draftId);
    if (draft.revision !== expectedRevision) fail('ERR_CONTEXT_STALE', 'A revisão do draft mudou.');
    const references = draft.references.filter((reference) => reference.reference_id !== referenceId);
    if (references.length === draft.references.length) fail('ERR_INVALID', 'Referência não pertence ao draft.');
    return this.saveDraft(auth, { ...draft, references, revision: expectedRevision });
  }


}

export function canonicalJSON(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('ERR_INVALID', 'Número não canônico.');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`;
  if (!isPlainObject(value)) fail('ERR_INVALID', 'Valor não suportado na canonicalização.');
  return `{${Object.keys(value).sort().filter((key) => value[key] !== undefined).map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
}

export async function readAuthorizedFile(root, relativePath, secureReaderPath) {
  if (typeof secureReaderPath !== 'string' || !path.isAbsolute(secureReaderPath)) fail('ERR_UNAVAILABLE', 'Leitor seguro não configurado.');
  if (typeof relativePath !== 'string' || path.isAbsolute(relativePath) || relativePath.split('/').some((part) => !part || part === '.' || part === '..')) fail('ERR_PATH_ESCAPE', 'Caminho inválido.');
  let fd;
  try {
    const expected = statSync(root);
    fd = openSync(root, fsConstants.O_RDONLY | fsConstants.O_DIRECTORY | fsConstants.O_NOFOLLOW);
    const opened = fstatSync(fd);
    if (!opened.isDirectory() || expected.dev !== opened.dev || expected.ino !== opened.ino) fail('ERR_PATH_ESCAPE', 'Root alterado durante abertura.');
    const result = spawnSync(secureReaderPath, [relativePath], { stdio: ['ignore', 'pipe', 'ignore', fd], maxBuffer: 4 * 1024 * 1024 + 1, timeout: 30_000 });
    if (result.error) fail(result.error.code === 'ETIMEDOUT' ? 'ERR_TIMEOUT' : 'ERR_UNAVAILABLE', 'Leitor seguro indisponível.');
    if (result.status === 10) fail('ERR_PATH_ESCAPE', 'Caminho ou symlink não autorizado.');
    if (result.status === 12) fail('ERR_INVALID', 'Fonte inválida ou grande demais.');
    if (result.status !== 0) fail('ERR_CONTEXT_STALE', 'Fonte indisponível.');
    return result.stdout;
  } catch (error) {
    if (error instanceof ComposerError) throw error;
    if (error.code === 'ELOOP' || error.code === 'ENOTDIR') fail('ERR_PATH_ESCAPE', 'Root não autorizado.');
    fail('ERR_CONTEXT_STALE', 'Fonte indisponível.');
  } finally { if (fd !== undefined) closeSync(fd); }
}
