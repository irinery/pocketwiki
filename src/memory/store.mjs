import { createHash, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { constants as fsConstants } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { mkdir, readFile, readdir, rename, writeFile, chmod, lstat, realpath, unlink, open } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

const EVENTS = new Set(['session-start', 'user-prompt-submit', 'assistant-response', 'stop', 'session-end']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEY = /^[A-Za-z0-9_-]{1,64}$/;
const STOPWORDS = new Set(['como', 'com', 'para', 'pelo', 'pela', 'que', 'qual', 'quais', 'uma', 'uns', 'das', 'dos', 'the', 'and', 'for', 'this']);
const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export function memoryNamespacePath(root, namespace) {
  if (!namespace || typeof namespace !== 'object' || !CANONICAL_UUID.test(namespace.environment_id || '')) {
    throw memoryError('ERR_INVALID', 'Invalid memory environment namespace');
  }
  const projectID = namespace.project_id;
  const threadID = namespace.thread_id;
  if ((projectID !== undefined && !CANONICAL_UUID.test(projectID)) ||
      (threadID !== undefined && !CANONICAL_UUID.test(threadID)) || (!projectID && !threadID)) {
    throw memoryError('ERR_INVALID', 'Invalid memory project or thread namespace');
  }
  const kind = projectID ? 'projects' : 'threads';
  const id = projectID || threadID;
  return path.join(path.resolve(root), 'v2', namespace.environment_id, kind, id);
}

function memoryError(code, message) {
  return Object.assign(new Error(message), { code });
}

async function secureDirectory(root, parts = []) {
  await mkdir(root, { recursive:true, mode:0o700 });
  const rootInfo = await lstat(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory root must be a real directory');
  let current = await realpath(root);
  for (const part of parts) {
    current = path.join(current, part);
    try { await mkdir(current, { mode:0o700 }); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory namespace contains a symlink');
    await chmod(current, 0o700);
  }
  return current;
}

const writeQueues = new Map();
function serializeWrite(key, operation) {
  const root = key.replace(/:(note|capture)$/, '');
  const previous = writeQueues.get(root) || Promise.resolve();
  const next = previous.catch(() => {}).then(async () => {
    const directory = await secureDirectory(root);
    const file = path.join(directory, '.harness-writer.sqlite3');
    let fd;
    try {
      fd = await open(file, fsConstants.O_CREAT | fsConstants.O_RDWR | fsConstants.O_NOFOLLOW, 0o600);
      const info = await fd.stat();
      if (!info.isFile()) throw memoryError('ERR_SCOPE', 'Invalid memory writer database');
      await fd.chmod(0o600);
    } finally { await fd?.close(); }
    const db = new DatabaseSync(file);
    try {
      db.exec('PRAGMA busy_timeout=5000; BEGIN IMMEDIATE');
      try {
        const result = await operation();
        db.exec('COMMIT');
        return result;
      } catch (cause) {
        try { db.exec('ROLLBACK'); } catch {}
        throw cause;
      }
    } catch (cause) {
      if (String(cause?.message || '').includes('database is locked')) throw memoryError('ERR_UNAVAILABLE', 'Memory writer lock unavailable');
      throw cause;
    } finally { db.close(); }
  });
  const queued = next.catch(() => {}).finally(() => {
    if (writeQueues.get(root) === queued) writeQueues.delete(root);
  });
  writeQueues.set(root, queued);
  return next;
}

export function defaultMemoryDirectory() {
  return process.platform === 'darwin'
    ? path.join(homedir(), 'Library/Application Support/PocketWiki/AI Memory')
    : path.join(process.env.XDG_DATA_HOME || path.join(homedir(), '.local/share'), 'pocketwiki/memory');
}

function words(value) {
  return [...new Set(String(value).normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase()
    .match(/[a-z0-9]{3,}/g)?.filter(word => !STOPWORDS.has(word)) || [])];
}

function score(content, terms) {
  const text = String(content).normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase();
  return terms.reduce((sum, term) => sum + (text.includes(term) ? 1 : 0), 0);
}

export function validateMemoryEvents(events, { unicodeScalars = false } = {}) {
  if (!Array.isArray(events) || events.length < 1 || events.length > 32) throw new Error('invalid_event_batch');
  return events.map(item => {
    if (!EVENTS.has(item?.event) || !UUID.test(item.session_id || '') || !KEY.test(item.ingest_key || '') ||
        (item.prompt != null && (typeof item.prompt !== 'string' || (unicodeScalars ? [...item.prompt].length : item.prompt.length) > 8000)) ||
        (item.message != null && (typeof item.message !== 'string' || (unicodeScalars ? [...item.message].length : item.message.length) > 8000)) ||
        (item.event === 'user-prompt-submit' && !item.prompt?.trim()) ||
        (item.event === 'assistant-response' && !item.message?.trim())) throw new Error('invalid_event');
    return {
      event:item.event,
      session_id:item.session_id.toLowerCase(),
      ingest_key:item.ingest_key,
      ...(item.prompt != null ? { prompt:item.prompt } : {}),
      ...(item.message != null ? { message:item.message } : {}),
      provider_id:typeof item.provider_id === 'string' ? item.provider_id.slice(0, 120) : null,
      model_id:typeof item.model_id === 'string' ? item.model_id.slice(0, 120) : null
    };
  });
}

export class PocketMemoryStore {
  constructor(root) {
    this.root = path.resolve(root);
    this.captureRoot = path.join(this.root, 'captures');
    this.writeTail = Promise.resolve();
  }

  async readNote() {
    try {
      return await readFile(path.join(this.root, 'MEMORY.md'), 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return '';
      throw error;
    }
  }

  async writeNote(content) {
    if (typeof content !== 'string' || Buffer.byteLength(content, 'utf8') > 16 * 1024) {
      throw new Error('invalid_memory_note');
    }
    await this.#writeAtomic(path.join(this.root, 'MEMORY.md'), content);
  }

  namespace(namespace) {
    return new PocketMemoryStore(memoryNamespacePath(this.root, namespace));
  }

  async noteGetCAS(namespace) {
    const directory = await secureDirectory(this.root);
    if (namespace) {
      const state = await readJSON(path.join(directory, '.memory-notes.json'), { sequence:0, notes:{}, events:[] });
      const item = state.notes[JSON.stringify([namespace.environment_id, namespace.project_id || null, namespace.thread_id || null])];
      return item ? { content:item.content, revision:item.revision } : { content:'', revision:0 };
    }
    const statePath = path.join(directory, '.memory-note.json');
    const notePath = path.join(directory, 'MEMORY.md');
    const state = await readJSON(statePath, null);
    if (state && Number.isSafeInteger(state.revision) && typeof state.content === 'string') {
      return { content:state.content, revision:state.revision };
    }
    const metadata = await readJSON(path.join(directory, '.memory-metadata.json'), { schema_version:2, revision:0 });
    const content = await readText(notePath, '');
    return { content, revision: metadata.revision };
  }

  notePutCAS(content, expectedRevision, namespace) {
    if (typeof content !== 'string' || Buffer.byteLength(content, 'utf8') > 16 * 1024 ||
        !Number.isSafeInteger(expectedRevision) || expectedRevision < 0) {
      return Promise.reject(memoryError('ERR_INVALID', 'Invalid memory note or revision'));
    }
    return serializeWrite(`${this.root}:note`, () => this.#putNoteLocked(content, expectedRevision, namespace));
  }

  async #putNoteLocked(content, expectedRevision, namespace) {
      await this.#recoverNoteIntent();
      await this.#recoverImportIntent();
      const current = await this.noteGetCAS(namespace);
      if (current.revision !== expectedRevision) {
        throw Object.assign(memoryError('ERR_CONFLICT', 'Memory note revision changed'), { revision:current.revision });
      }
      const next = { content, revision:current.revision + 1 };
      if (namespace) {
        const intent = await this.#makeNoteIntent(namespace, next);
        await this.#writeAtomic(path.join(this.root, '.note-intent.json'), JSON.stringify(intent));
        await this.#recoverNoteIntent();
        return next;
      }
      await this.#writeAtomic(path.join(this.root, '.memory-note.json'), JSON.stringify({ schema_version:2, ...next }));
      await this.#writeAtomic(path.join(this.root, 'MEMORY.md'), content);
      return next;
  }

  async #makeNoteIntent(namespace, next) {
    const state = await readJSON(path.join(this.root, '.memory-notes.json'), { sequence:0, notes:{}, events:[] });
    const key = JSON.stringify([namespace.environment_id, namespace.project_id || null, namespace.thread_id || null]);
    const value = { namespace:{ ...namespace, schema_version:2, note_revision:next.revision }, ...next };
    state.notes[key] = value;
    state.sequence += 1;
    state.events.push({ event_id:randomUUID(), sequence:state.sequence,
      entity_type:'MemoryNote', entity_key:key, change:'upsert', value });
    if (Buffer.byteLength(JSON.stringify(state)) > 16 * 1024 * 1024) throw memoryError('ERR_UNAVAILABLE', 'Memory note journal full');
    return { state, namespace, content:next.content };
  }

  async #recoverNoteIntent() {
    const intentPath = path.join(this.root, '.note-intent.json');
    const intent = await readJSON(intentPath, null);
    if (!intent) return;
    const namespace = intent.namespace;
    try { memoryNamespacePath('/memory-root', namespace); }
    catch { throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Invalid memory note intent'); }
    const key = JSON.stringify([namespace.environment_id, namespace.project_id || null, namespace.thread_id || null]);
    const value = intent.state?.notes?.[key];
    if (typeof intent.content !== 'string' || Buffer.byteLength(intent.content) > 16 * 1024 ||
        !Number.isSafeInteger(intent.state?.sequence) || intent.state.sequence < 1 ||
        !Array.isArray(intent.state.events) || value?.content !== intent.content ||
        !Number.isSafeInteger(value?.revision) || value.revision < 1) {
      throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Invalid memory note intent');
    }
    const encoded = JSON.stringify(intent.state);
    if (Buffer.byteLength(encoded) > 16 * 1024 * 1024) throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Memory note journal full');
    const noteDirectory = await secureDirectory(this.root, ['.notes', namespace.thread_id || 'project']);
    await this.#writeAtomic(path.join(noteDirectory, 'MEMORY.md'), intent.content);
    await this.#writeAtomic(path.join(this.root, '.memory-notes.json'), encoded);
    await unlink(intentPath);
  }

  scopedNoteGet(namespace) {
    return serializeWrite(`${this.root}:note`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverImportIntent();
      return this.noteGetCAS(namespace);
    });
  }

  notesProjection(namespace) {
    return serializeWrite(`${this.root}:note`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverImportIntent();
      const state = await readJSON(path.join(this.root, '.memory-notes.json'), { sequence:0, notes:{}, events:[] });
      const notes = Object.entries(state.notes).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
        .map(([, value]) => value)
        .filter((value) => !namespace.thread_id || value.namespace.thread_id === namespace.thread_id);
      return { notes, sequence:state.sequence };
    });
  }

  notesEvents(afterSequence) {
    return serializeWrite(`${this.root}:note`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverImportIntent();
      const state = await readJSON(path.join(this.root, '.memory-notes.json'), { sequence:0, notes:{}, events:[] });
      return state.events.filter((event) => event.sequence > afterSequence);
    });
  }

  notesRetentionAvailable(afterSequence) {
    return serializeWrite(`${this.root}:note`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverImportIntent();
      const state = await readJSON(path.join(this.root, '.memory-notes.json'), { sequence:0, notes:{}, events:[] });
      if (!Number.isSafeInteger(state.sequence) || state.sequence < afterSequence || !Array.isArray(state.events)) return false;
      const later = state.events.filter((event) => event.sequence > afterSequence);
      return later.length === state.sequence - afterSequence &&
        later.every((event, index) => event.sequence === afterSequence + index + 1);
    });
  }

  captureScoped(events) {
    const validated = validateMemoryEvents(events, { unicodeScalars:true });
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
      const ledgerPath = path.join(this.root, '.memory-receipts.json');
      await secureDirectory(this.root, ['captures']);
      const ledger = await readJSON(ledgerPath, { sequence:0, accepted_keys:{} });
      if (!ledger.accepted_keys || Array.isArray(ledger.accepted_keys)) ledger.accepted_keys = {};
      let sequence = ledger.sequence || 0;
      const byKey = new Map();
      const prepared = validated.map((item) => {
        const key = `${item.session_id}:${item.ingest_key}`;
        let assigned = ledger.accepted_keys[key] || byKey.get(key);
        if (!assigned) { assigned = ++sequence; byKey.set(key, assigned); }
        return { ...item, sequence:assigned };
      });
      for (const [key, assigned] of byKey) ledger.accepted_keys[key] = assigned;
      ledger.sequence = sequence;
      await this.#writeAtomic(path.join(this.root, '.capture-intent.json'), JSON.stringify({ events:prepared, ledger }));
      await this.#recoverCaptureIntent();
      return prepared.map((item) => item.ingest_key);
    });
  }

  recoverCapture() {
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
    });
  }

  scopedRecall(question, options) {
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
      return this.recall(question, options);
    });
  }

  scopedSessionsConsistent() {
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
      return this.scopedSessions();
    });
  }

  async #recoverCaptureIntent() {
    const file = path.join(this.root, '.capture-intent.json');
    const intent = await readJSON(file, null);
    if (!intent) return;
    if (!Array.isArray(intent.events) || !intent.ledger ||
        !Number.isSafeInteger(intent.ledger.sequence) || intent.ledger.sequence < 0 ||
        !intent.ledger.accepted_keys || typeof intent.ledger.accepted_keys !== 'object') {
      throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Memory capture intent is invalid');
    }
    const events = intent.events.map(({ sequence, ...event }) => ({ sequence, event }));
    const valid = validateMemoryEvents(events.map(({ event }) => event), { unicodeScalars:true });
    if (events.some(({ sequence }, index) => !Number.isSafeInteger(sequence) || sequence < 1 ||
        sequence > intent.ledger.sequence || intent.ledger.accepted_keys[`${valid[index].session_id}:${valid[index].ingest_key}`] !== sequence)) {
      throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Memory capture intent is invalid');
    }
    await this.#capture(valid.map((event, index) => ({ ...event, sequence:events[index].sequence })));
    await this.#writeAtomic(path.join(this.root, '.memory-receipts.json'), JSON.stringify(intent.ledger));
    await unlink(file);
  }

  async scopedSessions() {
    const records = [];
    const folder = this.captureRoot;
    let names;
    try { names = await readdir(folder); }
    catch (error) { if (error.code === 'ENOENT') return records; throw error; }
    for (const name of names.filter((item) => /^session-[0-9a-f-]{36}\.json$/.test(item))) {
      const filename = path.join(folder, name);
      try {
        const info = await lstat(filename);
        if (!info.isFile() || info.isSymbolicLink() || info.size > 16 * 1024 * 1024) continue;
        const record = JSON.parse(await readFile(filename, 'utf8'));
        if (record.id === name.slice(8, -5) && Array.isArray(record.messages)) records.push(record);
      } catch (error) { if (error.code !== 'ENOENT') continue; }
    }
    return records.sort((a, b) => String(a.id).localeCompare(String(b.id)));
  }

  async scopedEvents() {
    const records = await this.scopedSessions();
    return records.flatMap((record) => Array.isArray(record.events) ? record.events
      .filter((event) => Number.isSafeInteger(event.sequence) && event.sequence > 0)
      .map((event) => ({ session_id:record.id, event:event.event, ingest_key:event.ingest_key, sequence:event.sequence })) : []);
  }

  async scopedReceipts() {
    return readJSON(path.join(this.root, '.memory-receipts.json'), { sequence:0, accepted_keys:{} });
  }

  async importRecords(records, { namespace, note } = {}) {
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverNoteIntent();
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
      const normalized = records.map((record) => ({
        schema_version:1, id:record.id,
        created_at:record.created_at || new Date(0).toISOString(),
        updated_at:record.updated_at || new Date(0).toISOString(),
        messages:record.messages, events:Array.isArray(record.events) ? record.events : []
      }));
      if (new Set(normalized.map((record) => record.id)).size !== normalized.length) throw memoryError('ERR_IMPORT', 'Duplicate import session');
      await secureDirectory(this.root, ['captures']);
      for (const record of normalized) {
        const target = path.join(this.captureRoot, `session-${record.id}.json`);
        try { await lstat(target); throw memoryError('ERR_CONFLICT', 'Memory session already exists'); }
        catch (cause) { if (cause.code !== 'ENOENT') throw cause; }
      }
      let noteIntent;
      if (note !== undefined) {
        const current = await this.noteGetCAS(namespace);
        if (current.revision !== 0) throw Object.assign(memoryError('ERR_CONFLICT', 'Memory note revision changed'), { revision:current.revision });
        noteIntent = await this.#makeNoteIntent(namespace, { content:note.content, revision:1 });
      }
      const intent = { records:normalized, ...(noteIntent ? { note_intent:noteIntent } : {}) };
      if (Buffer.byteLength(JSON.stringify(intent)) > 32 * 1024 * 1024) throw memoryError('ERR_IMPORT', 'Memory import intent too large');
      await this.#writeAtomic(path.join(this.root, '.import-intent.json'), JSON.stringify(intent));
      await this.#recoverImportIntent();
      return normalized.length;
    });
  }

  async #recoverImportIntent() {
    const file = path.join(this.root, '.import-intent.json');
    const intent = await readJSON(file, null);
    if (!intent) return;
    if (!Array.isArray(intent.records) || intent.records.length > 500 ||
        intent.records.some((record) => !CANONICAL_UUID.test(record?.id || '') || !Array.isArray(record.messages) ||
          !Array.isArray(record.events)) || new Set(intent.records.map((record) => record.id)).size !== intent.records.length) {
      throw memoryError('ERR_MEMORY_UNAVAILABLE', 'Invalid memory import intent');
    }
    await secureDirectory(this.root, ['captures']);
    for (const record of intent.records) {
      const target = path.join(this.captureRoot, `session-${record.id}.json`);
      const existing = await readJSON(target, null);
      if (existing && !isDeepStrictEqual(existing, record)) throw memoryError('ERR_CONFLICT', 'Import session changed during recovery');
      if (!existing) await this.#writeAtomic(target, JSON.stringify(record, null, 2));
    }
    if (intent.note_intent) {
      await this.#writeAtomic(path.join(this.root, '.note-intent.json'), JSON.stringify(intent.note_intent));
      await this.#recoverNoteIntent();
    }
    await unlink(file);
  }

  async mapLegacySession(sessionID, legacyRoot = this.root) {
    return serializeWrite(`${this.root}:capture`, async () => {
      await this.#recoverCaptureIntent();
      await this.#recoverImportIntent();
      return this.#mapLegacySession(sessionID, legacyRoot);
    });
  }

  async #mapLegacySession(sessionID, legacyRoot) {
    if (!CANONICAL_UUID.test(sessionID || '')) throw memoryError('ERR_INVALID', 'Invalid legacy session ID');
    const legacyCandidates = [
      path.join(legacyRoot, `session-${sessionID}.json`),
      path.join(legacyRoot, 'captures', `session-${sessionID}.json`)
    ];
    let sourcePath;
    let record;
    for (const candidate of legacyCandidates) {
      try {
        const info = await lstat(candidate);
        if (!info.isFile() || info.isSymbolicLink() || info.size > 16 * 1024 * 1024) continue;
        sourcePath = candidate;
        record = JSON.parse(await readFile(candidate, 'utf8'));
        break;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    if (!record || record.id?.toLowerCase() !== sessionID) throw memoryError('ERR_IMPORT', 'Legacy session is not a valid v1 record');
    if (!Array.isArray(record.messages)) throw memoryError('ERR_IMPORT', 'Legacy session messages are invalid');
    const marker = path.join(this.root, '.legacy-mappings', `${sessionID}.json`);
    const prior = await readJSON(marker, null);
    const target = path.join(this.captureRoot, `session-${sessionID}.json`);
    const existing = await readJSON(target, null);
    if (prior && existing) return { mapped:true, session_id:sessionID };
    const events = Array.isArray(record.events) ? record.events : [];
    const imported = {
      schema_version:1,
      id:sessionID,
      created_at:typeof record.created_at === 'string' ? record.created_at : new Date(0).toISOString(),
      updated_at:typeof record.updated_at === 'string' ? record.updated_at : new Date(0).toISOString(),
      messages:record.messages.filter((item) => ['user', 'assistant'].includes(item?.role) && typeof item.content === 'string')
        .map((item) => ({ role:item.role, content:item.content, created_at:item.created_at || record.updated_at || record.created_at || new Date(0).toISOString() })),
      events
    };
    if (existing && !isDeepStrictEqual(existing, imported)) throw memoryError('ERR_CONFLICT', 'Legacy session already has a different scoped record');
    if (!existing) await this.#writeAtomic(target, JSON.stringify(imported, null, 2));
    await this.#writeAtomic(marker, JSON.stringify({ schema_version:1, session_id:sessionID, source:'legacy-v1', mapped_at:new Date().toISOString() }));
    if (!sourcePath) throw memoryError('ERR_IMPORT', 'Legacy source not found');
    return { mapped:true, session_id:sessionID };
  }

  capture(events) {
    const validated = validateMemoryEvents(events);
    const work = this.writeTail.then(() => this.#capture(validated));
    this.writeTail = work.catch(() => {});
    return work;
  }

  async #capture(events) {
    const records = new Map();
    const acceptedKeys = [];
    const now = new Date().toISOString();
    for (const item of events) {
      let record = records.get(item.session_id);
      if (!record) {
        const filename = path.join(this.captureRoot, `session-${item.session_id}.json`);
        try {
          const info = await lstat(filename);
          if (!info.isFile() || info.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory session path is not a regular file');
          record = JSON.parse(await readFile(filename, 'utf8'));
        } catch (error) {
          if (error.code !== 'ENOENT') throw error;
          record = { schema_version:1, id:item.session_id, created_at:now, updated_at:now, messages:[], events:[] };
        }
        if (record.id !== item.session_id || !Array.isArray(record.events) || !Array.isArray(record.messages)) {
          throw new Error('invalid_session_record');
        }
        records.set(item.session_id, record);
      }
      const existingIndex = record.events.findIndex(event => event.ingest_key === item.ingest_key);
      if (existingIndex >= 0) {
        if (item.sequence && !record.events[existingIndex].sequence) {
          record.events[existingIndex] = { ...record.events[existingIndex], sequence:item.sequence };
          record.updated_at = now;
        }
        acceptedKeys.push(item.ingest_key);
        continue;
      }
      if (record.events.length >= 5000) throw new Error('memory_session_full');
      record.events.push({ ...item, created_at:now });
      const content = item.event === 'user-prompt-submit' ? item.prompt
        : item.event === 'assistant-response' ? item.message : null;
      if (content) record.messages.push({
        role:item.event === 'user-prompt-submit' ? 'user' : 'assistant',
        content, created_at:now, provider_id:item.provider_id, model_id:item.model_id
      });
      record.updated_at = now;
      acceptedKeys.push(item.ingest_key);
    }
    for (const record of records.values()) {
      await this.#writeAtomic(path.join(this.captureRoot, `session-${record.id}.json`), JSON.stringify(record, null, 2));
    }
    return acceptedKeys;
  }

  async recall(question, { maxCharacters = 5000, limit = 3, includeNote = true, unicodeScalars = false } = {}) {
    if (typeof question !== 'string' || !question.trim() || (unicodeScalars ? [...question].length : question.length) > 2000) throw new Error('invalid_question');
    const terms = words(question);
    const blocks = [];
    let remaining = maxCharacters;
    const note = includeNote ? (await this.readNote()).trim() : '';
    if (note) {
      const block = `Fonte: MEMORY.md\n${note}`.slice(0, Math.min(3000, remaining));
      blocks.push(block);
      remaining -= block.length;
    }
    const candidates = await this.#sessionCandidates();
    const byID = new Map();
    for (const { source, record } of candidates) {
      if (!UUID.test(record?.id || '') || !Array.isArray(record.messages)) continue;
      const sessionID = record.id.toLowerCase();
      const messages = record.messages.slice(-500).filter(item =>
        ['user', 'assistant'].includes(item?.role) && typeof item.content === 'string'
      );
      let best = { score:0, index:-1 };
      messages.forEach((message, index) => {
        const rank = score(message.content, terms);
        if (rank >= best.score && rank > 0) best = { score:rank, index };
      });
      if (best.index < 0) continue;
      const excerptText = messages.slice(Math.max(0, best.index - 1), Math.min(messages.length, best.index + 2))
        .map(item => `[${item.role}] ${item.content}`).join('\n\n');
      const excerpt = unicodeScalars ? [...excerptText].slice(0, 2200).join('') : excerptText.slice(0, 2200);
      const candidate = { source, id:sessionID, score:best.score, excerpt,
        updated:Date.parse(record.updated_at || record.created_at) || 0 };
      const prior = byID.get(sessionID);
      if (!prior || candidate.score > prior.score || (candidate.score === prior.score && source === 'local')) {
        byID.set(sessionID, candidate);
      }
    }
    const hits = [...byID.values()].sort((a, b) => b.score - a.score || b.updated - a.updated || a.id.localeCompare(b.id)).slice(0, limit);
    for (const hit of hits) {
      if (remaining <= 0) break;
      const block = `Fonte: ${hit.source}/session-${hit.id}.json\n${hit.excerpt}`.slice(0, remaining);
      blocks.push(block);
      remaining -= block.length;
    }
    return { context:blocks.join('\n\n---\n\n'), hits:hits.map(({ source, id, score, excerpt }) => ({ source, id, score, snippet:excerpt })) };
  }

  async #sessionCandidates() {
    const entries = [];
    for (const [folder, source] of [[this.root, 'local'], [this.captureRoot, 'captured']]) {
      let names;
      try {
        names = (await readdir(folder)).filter(name => /^session-[0-9a-f-]{36}\.json$/i.test(name));
      } catch (error) {
        if (error.code === 'ENOENT') continue;
        throw error;
      }
      for (const name of names) {
        const filename = path.join(folder, name);
        try {
          const info = await lstat(filename);
          if (info.isFile() && !info.isSymbolicLink() && info.size <= 16 * 1024 * 1024) entries.push({ filename, source, mtime:info.mtimeMs });
        } catch {}
      }
    }
    entries.sort((a, b) => b.mtime - a.mtime);
    const records = await Promise.all(entries.slice(0, 500).map(async item => {
      try { return { source:item.source, record:JSON.parse(await readFile(item.filename, 'utf8')) }; }
      catch { return null; }
    }));
    return records.filter(Boolean);
  }

  async #writeAtomic(filename, content) {
    await secureDirectory(path.dirname(filename));
    const temporary = `${filename}.${randomUUID()}.tmp`;
    try {
      try {
        const existing = await lstat(filename);
        if (!existing.isFile() || existing.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory file path is not a regular file');
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await writeFile(temporary, content, { mode:0o600, flag:'wx' });
      await rename(temporary, filename);
      await chmod(filename, 0o600);
    } catch (error) {
      const { rm } = await import('node:fs/promises');
      await rm(temporary, { force:true }).catch(() => {});
      throw error;
    }
  }
}

async function readJSON(filename, fallback) {
  try {
    const info = await lstat(filename);
    if (!info.isFile() || info.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory metadata path is not a regular file');
    return JSON.parse(await readFile(filename, 'utf8'));
  }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

async function readText(filename, fallback) {
  try {
    const info = await lstat(filename);
    if (!info.isFile() || info.isSymbolicLink()) throw memoryError('ERR_SCOPE', 'Memory note path is not a regular file');
    return await readFile(filename, 'utf8');
  }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
