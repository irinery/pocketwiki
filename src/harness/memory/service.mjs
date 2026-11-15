import { createHash, randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { PocketMemoryStore, memoryNamespacePath, validateMemoryEvents } from '../../memory/store.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_IMPORT_BYTES = 16 * 1024 * 1024;

function error(code, message, extra = {}) {
  return Object.assign(new Error(message), { code, correlation_id:randomUUID(), retryable:false, ...extra });
}

function digest(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function deterministicUUID(value) {
  const bytes = Buffer.from(digest(value).slice(0, 32), 'hex');
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function validateNamespace(namespace, { recall = false } = {}) {
  if (!namespace || typeof namespace !== 'object' || Array.isArray(namespace) ||
      Object.keys(namespace).some((key) => !['environment_id', 'project_id', 'thread_id', 'schema_version', 'note_revision'].includes(key)) ||
      (!recall && (namespace.schema_version !== 2 || !Number.isSafeInteger(namespace.note_revision) || namespace.note_revision < 0))) {
    throw error('ERR_INVALID', 'Invalid memory namespace');
  }
  try { memoryNamespacePath('/memory-root', namespace); }
  catch (cause) { throw error(cause.code || 'ERR_INVALID', cause.message); }
  return Object.freeze({
    environment_id:namespace.environment_id,
    ...(namespace.project_id ? { project_id:namespace.project_id } : {}),
    ...(namespace.thread_id ? { thread_id:namespace.thread_id } : {})
  });
}

function authorize(auth, namespace, scope, { personal = false } = {}) {
  if (!auth || !UUID.test(auth.principal_id || '') || !UUID.test(auth.environment_id || '') ||
      !Array.isArray(auth.scopes) || auth.environment_id !== namespace.environment_id) {
    throw error('ERR_FORBIDDEN', 'Memory identity is not authorized for this environment');
  }
  if (!auth.scopes.includes(scope)) throw error('ERR_SCOPE', 'Memory scope is not authorized');
  if (namespace.project_id && auth.aggregate_id !== namespace.project_id) {
    throw error('ERR_SCOPE', 'Memory project is outside the authenticated aggregate');
  }
  if (namespace.thread_id && auth.thread_id !== namespace.thread_id) {
    throw error('ERR_SCOPE', 'Memory thread is outside the authenticated thread');
  }
  if (personal && !auth.scopes.includes('memory.personal.read')) {
    throw error('ERR_SCOPE', 'Personal memory scope is not authorized');
  }
  return auth;
}

function cleanContext(value) {
  return String(value).replace(/\u0000/g, '').slice(0, 5_000);
}

function redactExportText(value) {
  return String(value)
    .replace(/\bBearer\s+[A-Za-z0-9._~+/-]+=*/gi, '[redacted credential]')
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,})\b/g, '[redacted secret]')
    .replace(/(?:\/Users\/|\/home\/|\/private\/var\/|[A-Za-z]:\\Users\\)[^\s"'<>]*/g, '[redacted path]');
}

function sanitizeExportRecord(record) {
  const safe = {
    schema_version:1,
    id:record.id,
    created_at:record.created_at,
    updated_at:record.updated_at,
    messages:(record.messages || []).filter((item) => ['user', 'assistant'].includes(item?.role) && typeof item.content === 'string')
      .map((item) => ({ role:item.role, content:redactExportText(item.content), ...(item.created_at ? { created_at:item.created_at } : {}) })),
    events:(record.events || []).filter((item) => typeof item?.event === 'string').map((item) => ({
      event:item.event,
      session_id:record.id,
      ingest_key:item.ingest_key,
      ...(item.prompt ? { prompt:redactExportText(item.prompt) } : {}),
      ...(item.message ? { message:redactExportText(item.message) } : {}),
      ...(Number.isSafeInteger(item.sequence) ? { sequence:item.sequence } : {})
    }))
  };
  return safe;
}

function validateIOError(cause, fallback = 'ERR_UNAVAILABLE') {
  if (cause?.code && ['ERR_INVALID', 'ERR_FORBIDDEN', 'ERR_TIMEOUT', 'ERR_UNAVAILABLE',
    'ERR_INCOMPATIBLE', 'ERR_SCOPE', 'ERR_CONFLICT', 'ERR_IMPORT', 'ERR_MEMORY_UNAVAILABLE'].includes(cause.code)) {
    return error(cause.code, String(cause.message || 'Memory operation failed').slice(0, 1_024), {
      retryable:cause.retryable === true,
      ...(Number.isSafeInteger(cause.revision) ? { revision:cause.revision } : {})
    });
  }
  if (['invalid_event', 'invalid_event_batch', 'invalid_session_record', 'memory_session_full'].includes(cause?.message)) {
    return error('ERR_INVALID', 'Memory event batch is invalid');
  }
  return error(fallback, 'Memory store is unavailable', { retryable:true });
}

export class MemoryHarnessService {
  constructor({ root, now = () => Date.now(), pageSize = 100 } = {}) {
    if (typeof root !== 'string' || !root) throw error('ERR_INVALID', 'Memory store root is required');
    if (typeof now !== 'function' || !Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) {
      throw error('ERR_INVALID', 'Memory service configuration is invalid');
    }
    this.root = path.resolve(root);
    this.now = now;
    this.pageSize = pageSize;
  }

  async captureScoped(auth, { namespace:rawNamespace, events } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'memory.write');
    let validated;
    try { validated = validateMemoryEvents(events); }
    catch (cause) { throw validateIOError(cause, 'ERR_INVALID'); }
    try { return { accepted_keys:await (await this.#storeFor(namespace)).captureScoped(validated) }; }
    catch (cause) { throw validateIOError(cause); }
  }

  async recallScoped(auth, input = {}) {
    if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).some((key) =>
      !['environment_id', 'project_id', 'thread_id', 'question', 'include_personal_note'].includes(key))) {
      throw error('ERR_INVALID', 'Memory recall input is invalid');
    }
    const { environment_id, project_id, thread_id, question, include_personal_note } = input;
    if (!thread_id) throw error('ERR_INVALID', 'Memory recall thread is required');
    const namespace = validateNamespace({ environment_id, ...(project_id === undefined ? {} : { project_id }), thread_id }, { recall:true });
    if (typeof include_personal_note !== 'boolean') throw error('ERR_INVALID', 'include_personal_note must be boolean');
    authorize(auth, namespace, 'context.read', { personal:include_personal_note });
    if (typeof question !== 'string' || !question.trim() || [...question].length > 2_000) {
      throw error('ERR_INVALID', 'Memory question is invalid');
    }
    const store = await this.#storeFor(namespace);
    let result;
    try { result = await store.recall(question, { maxCharacters:5_000, limit:3, includeNote:false }); }
    catch (cause) { throw validateIOError(cause); }
    const hits = result.hits.map((hit) => {
      const snippet = cleanContext(hit.snippet);
      const source = 'history';
      const hash = digest(JSON.stringify({
        environment_id:namespace.environment_id, project_id:namespace.project_id || '',
        thread_id:namespace.thread_id || '', session_id:hit.id, snippet
      }));
      return {
        session_id:hit.id,
        message_id:deterministicUUID(`${hit.id}\u0000${snippet}`),
        source,
        snippet,
        sha256:hash,
        environment_id:namespace.environment_id,
        ...(namespace.project_id ? { project_id:namespace.project_id } : {}),
        trust:'historical',
        score:hit.score
      };
    });
    let context = cleanContext(result.context);
    let noteRevision = 0;
    if (include_personal_note) {
      const note = await store.noteGetCAS();
      noteRevision = note.revision;
      if (note.content) {
        const snippet = cleanContext(note.content).slice(0, 3_000);
        const hit = {
          session_id:deterministicUUID(`note\u0000${namespace.environment_id}\u0000${namespace.project_id || namespace.thread_id}`),
          message_id:deterministicUUID(`note\u0000${note.revision}\u0000${snippet}`),
          source:'note', snippet,
          sha256:digest(JSON.stringify({ namespace, revision:note.revision, snippet })),
          environment_id:namespace.environment_id,
          ...(namespace.project_id ? { project_id:namespace.project_id } : {}),
          trust:'historical', score:0
        };
        hits.unshift(hit);
        context = [`Fonte: MEMORY.md\n${snippet}`, context].filter(Boolean).join('\n\n---\n\n').slice(0, 5_000);
      }
    }
    return { context, hits, note_revision:noteRevision };
  }

  async noteGet(auth, { namespace:rawNamespace } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'memory.personal.read', { personal:true });
    try { return await (await this.#storeFor(namespace)).noteGetCAS(); }
    catch (cause) { throw validateIOError(cause); }
  }

  async notePut(auth, { namespace:rawNamespace, content, expected_revision } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'memory.write');
    if (typeof content !== 'string' || Buffer.byteLength(content, 'utf8') > 16 * 1024 ||
        !Number.isSafeInteger(expected_revision) || expected_revision < 0) {
      throw error('ERR_INVALID', 'Memory note or expected_revision is invalid');
    }
    try { return await (await this.#storeFor(namespace)).notePutCAS(content, expected_revision); }
    catch (cause) { throw validateIOError(cause); }
  }

  async mapLegacy(auth, { legacy_session_id, namespace:rawNamespace } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'memory.write');
    if (!UUID.test(legacy_session_id || '')) throw error('ERR_INVALID', 'Legacy session ID must be a UUID');
    try {
      const store = await this.#storeFor(namespace);
      const mappings = path.join(this.root, '.legacy-mappings');
      await mkdir(mappings, { mode:0o700 }).catch((cause) => { if (cause.code !== 'EEXIST') throw cause; });
      const info = await lstat(mappings);
      if (!info.isDirectory() || info.isSymbolicLink()) throw error('ERR_SCOPE', 'Invalid mapping directory');
      const marker = path.join(mappings, `${legacy_session_id}.json`);
      const intent = JSON.stringify({ principal_id:auth.principal_id, namespace });
      try { await writeFile(marker, intent, { mode:0o600, flag:'wx' }); }
      catch (cause) {
        if (cause.code !== 'EEXIST') throw cause;
        const markerInfo = await lstat(marker);
        if (!markerInfo.isFile() || markerInfo.isSymbolicLink()) throw error('ERR_SCOPE', 'Invalid mapping marker');
        if (await readFile(marker, 'utf8') !== intent) throw error('ERR_CONFLICT', 'Legacy session already mapped');
      }
      return await store.mapLegacySession(legacy_session_id, this.root);
    }
    catch (cause) { throw validateIOError(cause, 'ERR_IMPORT'); }
  }

  async importLegacy(auth, { legacy_session_id, namespace } = {}) {
    return this.mapLegacy(auth, { legacy_session_id, namespace });
  }

  async exportNamespace(auth, { namespace:rawNamespace, include_personal_note = false } = {}) {
    const namespace = validateNamespace(rawNamespace);
    if (typeof include_personal_note !== 'boolean') throw error('ERR_INVALID', 'include_personal_note must be boolean');
    authorize(auth, namespace, 'context.read', { personal:include_personal_note });
    const store = await this.#storeFor(namespace);
    const exported = {
      schema_version:2,
      namespace,
      sessions:(await store.scopedSessions()).map(sanitizeExportRecord),
      ...(include_personal_note ? { note:await store.noteGetCAS().then((note) => ({
        content:redactExportText(note.content), revision:note.revision
      })) } : {})
    };
    const content = JSON.stringify(exported);
    if (Buffer.byteLength(content) > MAX_IMPORT_BYTES) throw error('ERR_INVALID', 'Memory export exceeds the size limit');
    return { content, sha256:digest(content) };
  }

  async importNamespace(auth, { namespace:rawNamespace, content } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'memory.write');
    if (typeof content !== 'string' || Buffer.byteLength(content) > MAX_IMPORT_BYTES) {
      throw error('ERR_INVALID', 'Memory import exceeds the size limit');
    }
    let parsed;
    try { parsed = JSON.parse(content); }
    catch { throw error('ERR_IMPORT', 'Memory import JSON is invalid'); }
    const importedNamespace = parsed?.namespace;
    if (parsed?.schema_version !== 2 || !importedNamespace ||
        importedNamespace.environment_id !== namespace.environment_id ||
        importedNamespace.project_id !== namespace.project_id || importedNamespace.thread_id !== namespace.thread_id ||
        !Array.isArray(parsed.sessions) || parsed.sessions.length > 500) {
      throw error('ERR_IMPORT', 'Memory import schema or namespace is invalid');
    }
    if (parsed.note !== undefined && (!parsed.note || typeof parsed.note.content !== 'string' ||
        Buffer.byteLength(parsed.note.content) > 16 * 1024 || !Number.isSafeInteger(parsed.note.revision) || parsed.note.revision < 0)) {
      throw error('ERR_IMPORT', 'Memory import note is invalid');
    }
    const imported = [];
    for (const record of parsed.sessions) {
      if (!UUID.test(record?.id || '') || !Array.isArray(record.messages) || record.messages.length > 5_000 ||
          record.messages.some((message) => !['user', 'assistant'].includes(message?.role) ||
            typeof message.content !== 'string' || Buffer.byteLength(message.content) > 8_000)) {
        throw error('ERR_IMPORT', 'Memory import session is invalid');
      }
      const eventNames = new Set(['session-start', 'user-prompt-submit', 'assistant-response', 'stop', 'session-end']);
      if (record.events !== undefined && (!Array.isArray(record.events) || record.events.length > 5_000 ||
          record.events.some((item) => !eventNames.has(item?.event) || item.session_id !== record.id ||
            typeof item.ingest_key !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key)))) {
        throw error('ERR_IMPORT', 'Memory import event record is invalid');
      }
      imported.push(record);
    }
    const store = await this.#storeFor(namespace);
    try { await store.importRecords(imported); }
    catch (cause) { throw validateIOError(cause, 'ERR_IMPORT'); }
    if (parsed.note !== undefined) {
      try { await store.notePutCAS(parsed.note.content, 0); }
      catch (cause) { throw validateIOError(cause, 'ERR_IMPORT'); }
    }
    return { imported_count:imported.length };
  }

  async snapshot(auth, { namespace:rawNamespace, page_size = this.pageSize, cursor } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'context.read');
    if (!Number.isInteger(page_size) || page_size < 1 || page_size > this.pageSize) {
      throw error('ERR_INVALID', 'Memory snapshot page_size is invalid');
    }
    if (cursor !== undefined && (typeof cursor !== 'string' || !/^[0-9a-f-]{36}\.[0-9a-f-]{36}$/.test(cursor))) {
      throw error('ERR_INVALID', 'Memory snapshot cursor is invalid');
    }
    const store = await this.#storeFor(namespace);
    const snapshotsDir = path.join(store.root, '.snapshots');
    await mkdir(snapshotsDir, { recursive:true, mode:0o700 });
    const snapshotDirectoryInfo = await lstat(snapshotsDir);
    if (!snapshotDirectoryInfo.isDirectory() || snapshotDirectoryInfo.isSymbolicLink()) {
      throw error('ERR_SCOPE', 'Memory snapshot directory contains a symlink');
    }
    await chmod(snapshotsDir, 0o700);
    let snapshot;
    let offset = 0;
    let snapshotID;
    if (cursor !== undefined) {
      [snapshotID] = cursor.split('.');
      snapshot = await this.#readSnapshot(snapshotsDir, snapshotID);
      if (!snapshot || snapshot.expires_at_ms <= this.now()) throw error('ERR_CURSOR_EXPIRED', 'Memory snapshot expired');
      if (snapshot.principal_id !== auth.principal_id || JSON.stringify(snapshot.namespace) !== JSON.stringify(namespace)) {
        throw error('ERR_FORBIDDEN', 'Memory snapshot cursor is unauthorized');
      }
      if (snapshot.page_size !== page_size) throw error('ERR_INVALID', 'Memory snapshot page_size changed');
      const position = snapshot.cursors[cursor];
      if (!Number.isSafeInteger(position)) throw error('ERR_INVALID', 'Memory snapshot cursor is invalid');
      offset = position;
    } else {
      snapshotID = randomUUID();
      snapshot = await this.#collectSnapshot(auth, namespace, store, false);
      snapshot.snapshot_id = snapshotID;
      snapshot.principal_id = auth.principal_id;
      snapshot.namespace = namespace;
      snapshot.expires_at_ms = this.now() + 600_000;
      snapshot.page_size = page_size;
      snapshot.cursors = {};
    }
    const items = snapshot.items.slice(offset, offset + page_size);
    const nextOffset = offset + items.length;
    let nextCursor;
    if (nextOffset < snapshot.items.length) {
      nextCursor = `${snapshotID}.${randomUUID()}`;
      snapshot.cursors[nextCursor] = nextOffset;
    }
    await this.#writeSnapshot(snapshotsDir, snapshotID, snapshot);
    return {
      snapshot_id:snapshotID,
      revision:snapshot.revision,
      as_of_seq:snapshot.as_of_seq,
      items,
      ...(nextCursor ? { next_cursor:nextCursor } : {})
    };
  }

  async eventsSince(auth, { namespace:rawNamespace, after_seq = 0 } = {}) {
    const namespace = validateNamespace(rawNamespace);
    authorize(auth, namespace, 'context.read');
    if (!Number.isSafeInteger(after_seq) || after_seq < 0) throw error('ERR_INVALID', 'after_seq is invalid');
    const store = await this.#storeFor(namespace);
    const events = await store.scopedEvents();
    return events.filter((item) => item.sequence > after_seq).sort((a, b) => a.sequence - b.sequence);
  }

  async #storeFor(namespace) {
    const rootInfo = await lstat(this.root).catch(async (cause) => {
      if (cause.code !== 'ENOENT') throw cause;
      await mkdir(this.root, { recursive:true, mode:0o700 });
      return lstat(this.root);
    });
    if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw error('ERR_SCOPE', 'Memory store root contains a symlink');
    await chmod(this.root, 0o700);
    const kind = namespace.project_id ? 'projects' : 'threads';
    const identity = namespace.project_id || namespace.thread_id;
    let current = this.root;
    for (const part of ['v2', namespace.environment_id, kind, identity]) {
      current = path.join(current, part);
      try { await mkdir(current, { mode:0o700 }); }
      catch (cause) { if (cause.code !== 'EEXIST') throw validateIOError(cause); }
      const info = await lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink()) throw error('ERR_SCOPE', 'Memory namespace contains a symlink');
      await chmod(current, 0o700);
    }
    return new PocketMemoryStore(this.root).namespace(namespace);
  }

  async #collectSnapshot(auth, namespace, store, includeNote) {
    const sessions = await store.scopedSessions();
    const items = sessions.map((record) => ({
      collection:'history', session_id:record.id,
      updated_at:record.updated_at || record.created_at || '',
      sha256:digest(JSON.stringify(record)), trust:'historical'
    }));
    if (includeNote) {
      const note = await store.noteGetCAS();
      if (note.content) items.push({ collection:'note', note_revision:note.revision, sha256:digest(note.content), trust:'historical' });
    }
    items.sort((a, b) => a.collection.localeCompare(b.collection) ||
      String(a.session_id || '').localeCompare(String(b.session_id || '')));
    const receipts = await store.scopedReceipts();
    return { revision:receipts.sequence, as_of_seq:receipts.sequence, items };
  }

  async #readSnapshot(directory, id) {
    const file = path.join(directory, `snapshot-${id}.json`);
    try {
      const info = await lstat(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_IMPORT_BYTES) throw error('ERR_SCOPE', 'Invalid memory snapshot file');
      return JSON.parse(await readFile(file, 'utf8'));
    } catch (cause) { if (cause.code === 'ENOENT') return null; throw cause; }
  }

  async #writeSnapshot(directory, id, value) {
    const file = path.join(directory, `snapshot-${id}.json`);
    const temp = `${file}.${randomUUID()}.tmp`;
    await writeFile(temp, JSON.stringify(value), { mode:0o600, flag:'wx' });
    const { rename, chmod } = await import('node:fs/promises');
    await rename(temp, file);
    await chmod(file, 0o600);
  }
}

export const MemoryErrorCode = Object.freeze([
  'ERR_INVALID', 'ERR_FORBIDDEN', 'ERR_TIMEOUT', 'ERR_UNAVAILABLE',
  'ERR_INCOMPATIBLE', 'ERR_SCOPE', 'ERR_CONFLICT', 'ERR_IMPORT', 'ERR_MEMORY_UNAVAILABLE'
]);
