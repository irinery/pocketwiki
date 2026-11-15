import { validateAgainst } from '../contracts/validate.mjs';
import { fail, UUID } from './service.mjs';

// Snapshot assembler: a partial snapshot never replaces the visible projection.
export class ComposerProjection {
  #environmentID;
  #threadID;
  constructor({ environment_id, thread_id }) {
    if (!UUID.test(environment_id ?? '') || !UUID.test(thread_id ?? '')) fail('ERR_INVALID', 'Identidade da projeção inválida.');
    this.#environmentID = environment_id;
    this.#threadID = thread_id;
  }
  #revision = -1;
  #drafts = new Map();
  #pending = null;
  #lastSeq = 0;
  #lastEventID = null;
  #eventIDs = new Map();
  get drafts() { return [...this.#drafts.values()].sort((a, b) => a.draft_id.localeCompare(b.draft_id)).map((draft) => structuredClone(draft)); }
  get revision() { return this.#revision; }
  begin(page) {
    if (!validateAgainst('composerFeatureSnapshot', page).valid) fail('ERR_INVALID', 'Snapshot inválido.');
    if (page.revision < this.#revision || page.as_of_seq < this.#lastSeq) fail('ERR_CONTEXT_STALE', 'Snapshot mais antigo que a projeção.');
    this.#pending = { snapshot_id: page.snapshot_id, revision: page.revision, as_of_seq: page.as_of_seq, cursor: page.next_cursor, drafts: new Map(), events: new Map(), eventIDs: new Map(), eventBytes: 0 };
    this.#append(page);
    if (!page.next_cursor) this.#install();
  }
  buffer(event) {
    const pending = this.#pending;
    if (!pending || !event || !Number.isSafeInteger(event.seq) || event.seq < 0 || !UUID.test(event.event_id ?? '') || !validateAgainst('composerModuleEvent', event.payload).valid) fail('ERR_INVALID', 'Evento inválido.');
    if (event.environment_id !== this.#environmentID || event.thread_id !== this.#threadID) fail('ERR_FORBIDDEN', 'Evento de outra identidade.');
    if (event.seq <= pending.as_of_seq) return;
    if (pending.eventIDs.has(event.event_id) && pending.eventIDs.get(event.event_id) !== event.seq) fail('ERR_INVALID', 'event_id repetido com outra sequência.');
    const previous = pending.events.get(event.seq);
    if (previous) {
      if (JSON.stringify(previous) !== JSON.stringify(event)) fail('ERR_CONTEXT_STALE', 'Sequência duplicada divergente.');
      return;
    }
    const size = Buffer.byteLength(JSON.stringify(event));
    if (pending.eventBytes + size > 4 * 1024 * 1024) { this.#pending = null; fail('ERR_CURSOR_EXPIRED', 'Buffer de eventos excedido; reinicie o snapshot.'); }
    pending.eventBytes += size;
    pending.events.set(event.seq, structuredClone(event));
    pending.eventIDs.set(event.event_id, event.seq);
  }
  apply(event) {
    if (this.#pending) return this.buffer(event);
    if (!event || !UUID.test(event.event_id ?? '') || !Number.isSafeInteger(event.seq) || !validateAgainst('composerModuleEvent', event.payload).valid) fail('ERR_INVALID', 'Evento inválido.');
    if (event.environment_id !== this.#environmentID || event.thread_id !== this.#threadID) fail('ERR_FORBIDDEN', 'Evento de outra identidade.');
    if (this.#eventIDs.has(event.event_id) && this.#eventIDs.get(event.event_id) !== event.seq) fail('ERR_INVALID', 'event_id repetido com outra sequência.');
    if (event.seq <= this.#lastSeq) return;
    this.#applyTo(this.#drafts, event);
    this.#lastSeq = event.seq;
    this.#lastEventID = event.event_id;
    this.#eventIDs.set(event.event_id, event.seq);
  }
  finish(page) {
    const pending = this.#pending;
    if (!pending || !pending.cursor || !validateAgainst('composerFeatureSnapshot', page).valid || page.snapshot_id !== pending.snapshot_id || page.revision !== pending.revision || page.as_of_seq !== pending.as_of_seq) fail('ERR_INVALID', 'Página não pertence ao snapshot.');
    this.#append(page);
    pending.cursor = page.next_cursor;
    if (!page.next_cursor) this.#install();
  }
  #append(page) {
    for (const draft of page.drafts) {
      if (this.#pending.drafts.has(draft.draft_id)) fail('ERR_INVALID', 'Entidade duplicada no snapshot.');
      this.#pending.drafts.set(draft.draft_id, structuredClone(draft));
    }
  }
  #applyTo(drafts, event) {
    let key;
    try { key = JSON.parse(event.payload.entity_key); } catch { fail('ERR_INVALID', 'Chave de evento inválida.'); }
    if (typeof key !== 'string' || (event.payload.change === 'upsert' && event.payload.value.draft_id !== key)) fail('ERR_INVALID', 'Chave de evento divergente.');
    if (event.payload.change === 'upsert') drafts.set(key, structuredClone(event.payload.value));
    else drafts.delete(key);
  }
  #install() {
    const pending = this.#pending;
    const drafts = new Map(pending.drafts);
    let sequence = pending.as_of_seq;
    let revision = pending.revision;
    let eventID = null;
    for (const event of [...pending.events.values()].sort((a, b) => a.seq - b.seq)) {
      if (event.seq <= sequence) fail('ERR_INVALID', 'Sequência de eventos divergente.');
      this.#applyTo(drafts, event);
      sequence = event.seq;
      eventID = event.event_id;
    }
    this.#drafts = drafts;
    this.#revision = revision;
    this.#lastSeq = sequence;
    this.#lastEventID = eventID;
    this.#eventIDs = new Map(pending.eventIDs);
    this.#pending = null;
  }
}
