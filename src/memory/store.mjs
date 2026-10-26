import { randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, rename, stat, writeFile, chmod } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

const EVENTS = new Set(['session-start', 'user-prompt-submit', 'assistant-response', 'stop', 'session-end']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEY = /^[A-Za-z0-9_-]{1,64}$/;
const STOPWORDS = new Set(['como', 'com', 'para', 'pelo', 'pela', 'que', 'qual', 'quais', 'uma', 'uns', 'das', 'dos', 'the', 'and', 'for', 'this']);

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

function validateEvents(events) {
  if (!Array.isArray(events) || events.length < 1 || events.length > 32) throw new Error('invalid_event_batch');
  return events.map(item => {
    if (!EVENTS.has(item?.event) || !UUID.test(item.session_id || '') || !KEY.test(item.ingest_key || '') ||
        (item.prompt != null && (typeof item.prompt !== 'string' || item.prompt.length > 8000)) ||
        (item.message != null && (typeof item.message !== 'string' || item.message.length > 8000)) ||
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

  capture(events) {
    const validated = validateEvents(events);
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
      if (record.events.some(event => event.ingest_key === item.ingest_key)) {
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

  async recall(question, { maxCharacters = 5000, limit = 3 } = {}) {
    if (typeof question !== 'string' || !question.trim() || question.length > 2000) throw new Error('invalid_question');
    const terms = words(question);
    const blocks = [];
    let remaining = maxCharacters;
    const note = (await this.readNote()).trim();
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
      const excerpt = messages.slice(Math.max(0, best.index - 1), Math.min(messages.length, best.index + 2))
        .map(item => `[${item.role}] ${item.content}`).join('\n\n').slice(0, 2200);
      const candidate = { source, id:sessionID, score:best.score, excerpt,
        updated:Date.parse(record.updated_at || record.created_at) || 0 };
      const prior = byID.get(sessionID);
      if (!prior || candidate.score > prior.score || (candidate.score === prior.score && source === 'local')) {
        byID.set(sessionID, candidate);
      }
    }
    const hits = [...byID.values()].sort((a, b) => b.score - a.score || b.updated - a.updated).slice(0, limit);
    for (const hit of hits) {
      if (remaining <= 0) break;
      const block = `Fonte: ${hit.source}/session-${hit.id}.json\n${hit.excerpt}`.slice(0, remaining);
      blocks.push(block);
      remaining -= block.length;
    }
    return { context:blocks.join('\n\n---\n\n'), hits:hits.map(({ source, id, score }) => ({ source, id, score })) };
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
          const info = await stat(filename);
          if (info.isFile() && info.size <= 16 * 1024 * 1024) entries.push({ filename, source, mtime:info.mtimeMs });
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
    await mkdir(path.dirname(filename), { recursive:true, mode:0o700 });
    const temporary = `${filename}.${randomUUID()}.tmp`;
    try {
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
