import { validateAgainst } from '../../harness/contracts/validate.mjs';

const valid = (name, value) => validateAgainst(name, value).valid;
const fail = (code, message) => Object.assign(new Error(message), { code });
const clone = value => structuredClone(value);

// A snapshot is staged until every page has been validated. A caller only
// publishes finish(), so a bad page or event cannot partially update the UI.
export class RuntimeProjection {
  constructor({ environmentId, threadId, pageSize = 100, confirmedRevision = 0, confirmedSeq = 0 }) {
    Object.assign(this, { environmentId, threadId, pageSize, confirmedRevision, confirmedSeq });
    this.receipts = new Map(); this.effects = new Map(); this.events = [];
    this.cursors = new Set(); this.seen = new Map(); this.sequences = new Map(); this.bytes = 0;
  }
  appendPage(page, requestedCursor) {
    const d = page?.data;
    if (this.complete || !valid('snapshotEnvelope', page) || page.module !== 'runtime' ||
        (!this.started ? requestedCursor != null : requestedCursor !== this.nextCursor || requestedCursor == null) ||
        d.receipts.length + d.effects.length > this.pageSize || d.revision < this.confirmedRevision ||
        (this.started && (d.snapshot_id !== this.snapshotId || d.revision !== this.revision || d.as_of_seq !== this.boundary)) ||
        (d.next_cursor != null && (new TextEncoder().encode(d.next_cursor).length > 512 || this.cursors.has(d.next_cursor)))) throw fail('ERR_INVALID', 'Snapshot inválido');
    const receipts = new Map(this.receipts), effects = new Map(this.effects);
    for (const item of d.receipts) {
      if (receipts.has(item.command_id) || item.revision > d.revision) throw fail('ERR_INVALID', 'Receipt inválido');
      receipts.set(item.command_id, clone(item));
    }
    for (const item of d.effects) {
      if (effects.has(item.effect_id)) throw fail('ERR_INVALID', 'Efeito duplicado');
      effects.set(item.effect_id, clone(item));
    }
    this.receipts = receipts; this.effects = effects; this.started = true;
    this.snapshotId = d.snapshot_id; this.revision = d.revision; this.boundary = d.as_of_seq;
    this.nextCursor = d.next_cursor; this.complete = d.next_cursor == null;
    if (d.next_cursor != null) this.cursors.add(d.next_cursor);
  }
  bufferEvent(event, resolvedPayload) {
    if (event?.protocol_major !== 1) throw fail('ERR_INCOMPATIBLE', 'Versão do stream incompatível');
    if (!this.started || !valid('streamEnvelope', event) || event.environment_id !== this.environmentId || event.thread_id !== this.threadId || event.module !== 'runtime') throw fail('ERR_INVALID', 'Evento inválido');
    const payload = event.delivery === 'inline' && resolvedPayload === undefined ? event.payload : event.delivery === 'reference' ? resolvedPayload : undefined;
    if (!valid('runtimeModuleEvent', payload)) throw fail('ERR_INVALID', 'Payload inválido');
    if (event.seq <= this.boundary) return;
    const fingerprint = JSON.stringify([event, payload]);
    if (this.seen.has(event.event_id)) {
      if (this.seen.get(event.event_id) === fingerprint) return;
      throw fail('ERR_INVALID', 'Evento conflitante');
    }
    if (this.sequences.has(event.seq) || event.seq <= (this.events.at(-1)?.seq ?? this.boundary)) throw fail('ERR_INVALID', 'Sequência inválida');
    const size = new TextEncoder().encode(fingerprint).length;
    if (this.bytes + size > 4_194_304) throw fail('ERR_INVALID', 'Buffer excedido');
    this.bytes += size; this.seen.set(event.event_id, fingerprint); this.sequences.set(event.seq, event.event_id);
    this.events.push({ seq: event.seq, payload: clone(payload) });
  }
  finish() {
    if (!this.complete) throw fail('ERR_INVALID', 'Snapshot incompleto');
    const lastSeq = this.events.at(-1)?.seq ?? this.boundary;
    if (lastSeq < this.confirmedSeq) throw fail('ERR_INVALID', 'Snapshot desatualizado');
    const receipts = new Map(this.receipts), effects = new Map(this.effects);
    let revision = this.revision;
    for (const { payload: p } of this.events) {
      let key; try { key = JSON.parse(p.entity_key); } catch { throw fail('ERR_INVALID', 'Chave inválida'); }
      if (typeof key !== 'string' || JSON.stringify(key) !== p.entity_key) throw fail('ERR_INVALID', 'Chave inválida');
      if (p.entity_type === 'RuntimeEvent') {
        if (p.change === 'upsert' && (p.value?.event_id !== key || p.value?.thread_id !== this.threadId)) throw fail('ERR_INVALID', 'Evento inconsistente');
        continue;
      }
      const map = p.entity_type === 'RuntimeReceipt' ? receipts : p.entity_type === 'EffectRecord' ? effects : null;
      const field = p.entity_type === 'RuntimeReceipt' ? 'command_id' : 'effect_id';
      if (!map) throw fail('ERR_INVALID', 'Entidade inválida');
      if (p.change === 'delete') map.delete(key);
      else if (p.change === 'upsert' && p.value?.[field] === key) {
        if (p.entity_type === 'RuntimeReceipt') {
          if (p.value.revision < (map.get(key)?.revision ?? 0)) throw fail('ERR_INVALID', 'Revisão regressiva');
          revision = Math.max(revision, p.value.revision);
        }
        map.set(key, clone(p.value));
      } else throw fail('ERR_INVALID', 'Mutação inválida');
    }
    return { snapshotId: this.snapshotId, revision, asOfSeq: this.boundary, lastSeq, receipts, effects };
  }
}
