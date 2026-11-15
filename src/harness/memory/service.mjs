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

function exactInput(input, fields) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).some((key) => !fields.includes(key)) ||
      fields.some((key) => !Object.hasOwn(input, key))) {
    throw error('ERR_INVALID', 'Memory input is invalid');
  }
  return input;
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
  if (!namespace.thread_id && auth.thread_id) {
    throw error('ERR_SCOPE', 'Thread-bound credential cannot access project-wide memory');
  }
  if (personal && !auth.scopes.includes('memory.personal.read')) {
    throw error('ERR_SCOPE', 'Personal memory scope is not authorized');
  }
  return auth;
}

function cleanContext(value) {
  return [...String(value).replace(/\u0000/g, '')].slice(0, 5_000).join('');
}

function utf8Prefix(value, limit) {
  let bytes = 0;
  let result = '';
  for (const scalar of value) {
    const size = Buffer.byteLength(scalar, 'utf8');
    if (bytes + size > limit) break;
    result += scalar;
    bytes += size;
  }
  return result;
}

function validateScopedEvents(events) {
  if (!Array.isArray(events) || events.length < 1 || events.length > 32) throw error('ERR_INVALID', 'Invalid memory event batch');
  for (const item of events) {
    if (!item || typeof item !== 'object' || Array.isArray(item) || !UUID.test(item.session_id || '') ||
        Object.keys(item).some((key) => !['event', 'session_id', 'ingest_key', 'prompt', 'message', 'provider_id', 'model_id'].includes(key)) ||
        ['prompt', 'message', 'provider_id', 'model_id'].some((key) => Object.hasOwn(item, key) && typeof item[key] !== 'string') ||
        ['provider_id', 'model_id'].some((key) => item[key] !== undefined && [...item[key]].length > 120) ||
        (item.event !== 'user-prompt-submit' && item.prompt !== undefined) ||
        (item.event !== 'assistant-response' && item.message !== undefined)) {
      throw error('ERR_INVALID', 'Invalid memory event');
    }
  }
  return validateMemoryEvents(events, { unicodeScalars:true });
}

function redactExportText(value) {
  const withBasicRedacted = String(value).replace(/\bBasic\s+([^\s,;"'<>()[\]{}]+)/gi, (match, token) => {
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(token)) return match;
    const unpadded = token.replace(/=+$/, '');
    if (unpadded.length % 4 === 1) return match;
    const padded = unpadded + '='.repeat((4 - unpadded.length % 4) % 4);
    if (token.includes('=') && token !== padded) return match;
    const bytes = Buffer.from(padded, 'base64');
    return bytes.toString('base64') === padded && bytes.includes(0x3a) ? '[redacted credential]' : match;
  });
  return withBasicRedacted
    .replace(/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g, '[redacted private key]')
    .replace(/\bBearer\s+[A-Za-z0-9._~+/-]+=*/gi, '[redacted credential]')
    .replace(/\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|senha|token)["']?\s*[:=]\s*)(?:"(?:\\[\s\S]|[^"\\]|\\$)*(?:"|$)|'(?:\\[\s\S]|[^'\\]|\\$)*(?:'|$)|[^\s,;]+)/gi, '$1[redacted secret]')
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b/g, '[redacted secret]')
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/@:]+:[^\s/@]+@/gi, '$1[redacted credential]@')
    .replace(/\bfile:\/\/[^\s"'<>]+/gi, '[redacted path]')
    .replace(/(^|[\s("'=])\\\\[^\s"'<>]+/g, '$1[redacted path]')
    .replace(/(^|[\s("'=])(?:\/(?!\/)[^\s"'<>]+|[A-Za-z]:\\[^\s"'<>]+)/g, '$1[redacted path]');
}

function sanitizeExportRecord(record) {
  const timestamp = (value) => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value) ? value : undefined;
  const eventNames = new Set(['session-start', 'user-prompt-submit', 'assistant-response', 'stop', 'session-end']);
  const safe = {
    schema_version:1,
    id:record.id,
    ...(timestamp(record.created_at) ? { created_at:record.created_at } : {}),
    ...(timestamp(record.updated_at) ? { updated_at:record.updated_at } : {}),
    messages:(record.messages || []).filter((item) => ['user', 'assistant'].includes(item?.role) && typeof item.content === 'string')
      .map((item) => ({ role:item.role, content:redactExportText(item.content), ...(timestamp(item.created_at) ? { created_at:item.created_at } : {}) })),
    events:(record.events || []).filter((item) => eventNames.has(item?.event) && typeof item.ingest_key === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key)).map((item) => ({
      event:item.event,
      session_id:record.id,
      ingest_key:digest(`memory-export\u0000${item.ingest_key}`),
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
  constructor({ root, now = () => Date.now(), pageSize = 100, policy, association } = {}) {
    if (typeof root !== 'string' || !root) throw error('ERR_INVALID', 'Memory store root is required');
    if (typeof now !== 'function' || !Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) {
      throw error('ERR_INVALID', 'Memory service configuration is invalid');
    }
    this.root = path.resolve(root);
    this.now = now;
    this.pageSize = pageSize;
    if (policy !== undefined && typeof policy !== 'function') throw error('ERR_INVALID', 'Memory policy port is invalid');
    if (association !== undefined && typeof association !== 'function') throw error('ERR_INVALID', 'Memory association port is invalid');
    this.policy = policy;
    this.association = association;
  }

  async #authorize(auth, namespace, scope, options = {}) {
    authorize(auth, namespace, scope, options);
    if (!this.policy) throw error('ERR_UNAVAILABLE', 'Memory policy port is unavailable', { retryable:true });
    let granted;
    try { granted = await this.policy(auth, { namespace, scope, personal:options.personal === true }); }
    catch { throw error('ERR_UNAVAILABLE', 'Memory policy port is unavailable', { retryable:true }); }
    if (granted !== true) throw error('ERR_FORBIDDEN', 'Memory policy denied access');
    if (namespace.project_id && namespace.thread_id) {
      if (!this.association) throw error('ERR_UNAVAILABLE', 'Memory association port is unavailable', { retryable:true });
      let associated;
      try { associated = await this.association(auth, namespace); }
      catch { throw error('ERR_UNAVAILABLE', 'Memory association port is unavailable', { retryable:true }); }
      if (associated !== true) throw error('ERR_FORBIDDEN', 'Memory association denied access');
    }
  }

  async captureScoped(auth, input) {
    const { namespace:rawNamespace, events } = exactInput(input, ['namespace', 'events']);
    const namespace = validateNamespace(rawNamespace);
    let validated;
    try { validated = validateScopedEvents(events); }
    catch (cause) { throw validateIOError(cause, 'ERR_INVALID'); }
    await this.#authorize(auth, namespace, 'memory.write');
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
    if (typeof question !== 'string' || !question.trim() || [...question].length > 2_000) {
      throw error('ERR_INVALID', 'Memory question is invalid');
    }
    await this.#authorize(auth, namespace, 'context.read', { personal:include_personal_note });
    const store = await this.#storeFor(namespace);
    const note = include_personal_note ? await store.scopedNoteGet(namespace) : undefined;
    let result;
    try { result = await store.scopedRecall(question, { maxCharacters:5_000, limit:note?.content ? 2 : 3, includeNote:false, unicodeScalars:true }); }
    catch (cause) { throw validateIOError(cause); }
    const hits = result.hits.map((hit) => {
      const snippet = utf8Prefix(cleanContext(hit.snippet), 4_096);
      const source = 'history';
      const hash = digest(snippet);
      return {
        session_id:hit.id,
        message_id:deterministicUUID(`${hit.id}\u0000${snippet}`),
        source,
        snippet,
        sha256:hash,
        environment_id:namespace.environment_id,
        ...(namespace.project_id ? { project_id:namespace.project_id } : {}),
        trust:'historical'
      };
    });
    let context = cleanContext(result.context);
    let noteRevision = 0;
    if (include_personal_note) {
      noteRevision = note.revision;
      if (note.content) {
        const snippet = utf8Prefix([...cleanContext(note.content)].slice(0, 3_000).join(''), 4_096);
        const hit = {
          session_id:deterministicUUID(`note\u0000${namespace.environment_id}\u0000${namespace.project_id || namespace.thread_id}`),
          message_id:deterministicUUID(`note\u0000${note.revision}\u0000${snippet}`),
          source:'note', snippet,
          sha256:digest(snippet),
          environment_id:namespace.environment_id,
          ...(namespace.project_id ? { project_id:namespace.project_id } : {}),
          trust:'historical'
        };
        hits.unshift(hit);
        context = [`Fonte: MEMORY.md\n${snippet}`, context].filter(Boolean).join('\n\n---\n\n').slice(0, 5_000);
      }
    }
    return { context, hits, note_revision:noteRevision };
  }

  async noteGet(auth, input) {
    const { namespace:rawNamespace } = exactInput(input, ['namespace']);
    const namespace = validateNamespace(rawNamespace);
    await this.#authorize(auth, namespace, 'memory.personal.read', { personal:true });
    try { return await (await this.#storeFor(namespace)).scopedNoteGet(namespace); }
    catch (cause) { throw validateIOError(cause); }
  }

  async notePut(auth, input) {
    const { namespace:rawNamespace, content, expected_revision } = exactInput(input, ['namespace', 'content', 'expected_revision']);
    const namespace = validateNamespace(rawNamespace);
    if (typeof content !== 'string' || Buffer.byteLength(content, 'utf8') > 16 * 1024 ||
        !Number.isSafeInteger(expected_revision) || expected_revision < 0) {
      throw error('ERR_INVALID', 'Memory note or expected_revision is invalid');
    }
    await this.#authorize(auth, namespace, 'memory.write');
    try { return await (await this.#storeFor(namespace)).notePutCAS(content, expected_revision, namespace); }
    catch (cause) { throw validateIOError(cause); }
  }

  async mapLegacy(auth, input) {
    const { legacy_session_id, namespace:rawNamespace } = exactInput(input, ['legacy_session_id', 'namespace']);
    const namespace = validateNamespace(rawNamespace);
    if (!UUID.test(legacy_session_id || '')) throw error('ERR_INVALID', 'Legacy session ID must be a UUID');
    await this.#authorize(auth, namespace, 'memory.write');
    try {
      const store = await this.#storeFor(namespace);
      let sourceValid = false;
      for (const parent of [this.root, path.join(this.root, 'captures')]) {
        const parentInfo = await lstat(parent).catch((cause) => { if (cause.code === 'ENOENT') return null; throw cause; });
        if (!parentInfo) continue;
        if (!parentInfo.isDirectory() || parentInfo.isSymbolicLink()) throw error('ERR_SCOPE', 'Invalid legacy source directory');
        const source = path.join(parent, `session-${legacy_session_id}.json`);
        const info = await lstat(source).catch((cause) => { if (cause.code === 'ENOENT') return null; throw cause; });
        if (!info) continue;
        if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_IMPORT_BYTES) throw error('ERR_IMPORT', 'Invalid legacy source');
        let record;
        try { record = JSON.parse(await readFile(source, 'utf8')); } catch { throw error('ERR_IMPORT', 'Invalid legacy source'); }
        if (record?.schema_version !== 1 || record.id !== legacy_session_id || !Array.isArray(record.messages)) {
          throw error('ERR_IMPORT', 'Invalid legacy source');
        }
        sourceValid = true;
        break;
      }
      if (!sourceValid) throw error('ERR_IMPORT', 'Legacy source is missing');
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
        let existing;
        try { existing = JSON.parse(await readFile(marker, 'utf8')); }
        catch { throw error('ERR_IMPORT', 'Legacy mapping marker is invalid'); }
        const prior = existing?.namespace;
        if (existing?.principal_id !== auth.principal_id || prior?.environment_id !== namespace.environment_id ||
            prior?.project_id !== namespace.project_id || prior?.thread_id !== namespace.thread_id) {
          throw error('ERR_CONFLICT', 'Legacy session already mapped');
        }
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
    await this.#authorize(auth, namespace, 'context.read', { personal:include_personal_note });
    const store = await this.#storeFor(namespace);
    const exported = {
      schema_version:2,
      namespace,
      sessions:(await store.scopedSessionsConsistent()).map(sanitizeExportRecord),
      ...(include_personal_note ? { note:await store.scopedNoteGet(namespace).then((note) => ({
        content:redactExportText(note.content), revision:note.revision
      })) } : {})
    };
    const content = JSON.stringify(exported);
    if (Buffer.byteLength(content) > MAX_IMPORT_BYTES) throw error('ERR_INVALID', 'Memory export exceeds the size limit');
    return { content, sha256:digest(content) };
  }

  async importNamespace(auth, { namespace:rawNamespace, content } = {}) {
    const namespace = validateNamespace(rawNamespace);
    await this.#authorize(auth, namespace, 'memory.write');
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
            typeof item.ingest_key !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key) ||
            (item.sequence !== undefined && (!Number.isSafeInteger(item.sequence) || item.sequence < 1))))) {
        throw error('ERR_IMPORT', 'Memory import event record is invalid');
      }
      try {
        for (const item of record.events || []) {
          const { sequence, ...event } = item;
          validateScopedEvents([event]);
        }
      } catch { throw error('ERR_IMPORT', 'Memory import event record is invalid'); }
      imported.push(record);
    }
    const store = await this.#storeFor(namespace);
    try { await store.importRecords(imported, { namespace, note:parsed.note }); }
    catch (cause) { throw validateIOError(cause, 'ERR_IMPORT'); }
    return { imported_count:imported.length };
  }

  async snapshot(auth, { namespace:rawNamespace, page_size, cursor } = {}) {
    const namespace = validateNamespace(rawNamespace);
    await this.#authorize(auth, namespace, 'context.read', { personal:true });
    if (page_size !== undefined && (!Number.isInteger(page_size) || page_size < 1 || page_size > this.pageSize)) {
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
      if (!snapshot || snapshot.snapshot_id !== snapshotID || !Number.isSafeInteger(snapshot.expires_at_ms) ||
          !Number.isSafeInteger(snapshot.as_of_seq) || !Number.isInteger(snapshot.page_size) ||
          !Array.isArray(snapshot.items) || !snapshot.cursors || typeof snapshot.cursors !== 'object' ||
          snapshot.expires_at_ms <= this.now()) throw error('ERR_CURSOR_EXPIRED', 'Memory snapshot expired');
      if (snapshot.principal_id !== auth.principal_id || JSON.stringify(snapshot.namespace) !== JSON.stringify(namespace)) {
        throw error('ERR_FORBIDDEN', 'Memory snapshot cursor is unauthorized');
      }
      const retained = await store.notesRetentionAvailable(snapshot.as_of_seq).catch((cause) => {
        if (cause instanceof SyntaxError) return false;
        throw cause;
      });
      if (!retained) throw error('ERR_CURSOR_EXPIRED', 'Memory snapshot retention lost');
      if (page_size !== undefined && snapshot.page_size !== page_size) throw error('ERR_INVALID', 'Memory snapshot page_size changed');
      page_size = snapshot.page_size;
      const position = snapshot.cursors[cursor];
      if (!Number.isSafeInteger(position)) throw error('ERR_INVALID', 'Memory snapshot cursor is invalid');
      offset = position;
    } else {
      page_size ??= this.pageSize;
      snapshotID = randomUUID();
      snapshot = await this.#collectSnapshot(auth, namespace, store, false);
      snapshot.snapshot_id = snapshotID;
      snapshot.principal_id = auth.principal_id;
      snapshot.namespace = namespace;
      snapshot.expires_at_ms = this.now() + 600_000;
      snapshot.page_size = page_size;
      snapshot.cursors = {};
      for (let position = page_size; position < snapshot.items.length; position += page_size) {
        snapshot.cursors[`${snapshotID}.${randomUUID()}`] = position;
      }
      await this.#writeSnapshot(snapshotsDir, snapshotID, snapshot);
    }
    const items = snapshot.items.slice(offset, offset + page_size);
    const nextOffset = offset + items.length;
    let nextCursor;
    if (nextOffset < snapshot.items.length) {
      nextCursor = Object.keys(snapshot.cursors).find((key) => snapshot.cursors[key] === nextOffset);
      if (!nextCursor) throw error('ERR_CURSOR_EXPIRED', 'Memory snapshot cursor was lost');
    }
    return {
      snapshot_id:snapshotID,
      revision:snapshot.revision,
      as_of_seq:snapshot.as_of_seq,
      notes:items,
      ...(nextCursor ? { next_cursor:nextCursor } : {})
    };
  }

  async eventsSince(auth, { namespace:rawNamespace, after_seq = 0 } = {}) {
    const namespace = validateNamespace(rawNamespace);
    await this.#authorize(auth, namespace, 'context.read', { personal:true });
    if (!Number.isSafeInteger(after_seq) || after_seq < 0) throw error('ERR_INVALID', 'after_seq is invalid');
    const store = await this.#storeFor(namespace);
    const events = await store.notesEvents(after_seq);
    return events.filter((item) => !namespace.thread_id || item.value.namespace.thread_id === namespace.thread_id);
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
    const store = new PocketMemoryStore(this.root).namespace(namespace);
    try { await store.recoverCapture(); }
    catch (cause) { throw validateIOError(cause, 'ERR_MEMORY_UNAVAILABLE'); }
    return store;
  }

  async #collectSnapshot(auth, namespace, store, includeNote) {
    const projection = await store.notesProjection(namespace);
    return { revision:projection.sequence, as_of_seq:projection.sequence, items:projection.notes };
  }

  async #readSnapshot(directory, id) {
    const file = path.join(directory, `snapshot-${id}.json`);
    try {
      const info = await lstat(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_IMPORT_BYTES) throw error('ERR_SCOPE', 'Invalid memory snapshot file');
      return JSON.parse(await readFile(file, 'utf8'));
    } catch (cause) { if (cause.code === 'ENOENT' || cause instanceof SyntaxError) return null; throw cause; }
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
