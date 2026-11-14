import { validateAgainst, validateOperationInput } from '../contracts/validate.mjs';
import registry from '../contracts/operation-registry.json' with { type: 'json' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const MAX_BODY = 4 * 1024 * 1024;
const int = n => Number.isSafeInteger(n) && n >= 0;
const uuid = value => typeof value === 'string' && UUID.test(value);
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));

/** HTTP boundary only: Kernel owns authorization, ledger, and recovery. */
export class RuntimeTransport {
  #base; #bearer; #fetch; #timeout; #commandTimeout;
  constructor({ baseURL, bearer, fetchImpl = fetch, timeoutMS = 30000, commandTimeoutMS = 5000 }) {
    const base = new URL(baseURL);
    if (base.username || base.password || base.search || base.hash || base.pathname !== '/' || !(base.protocol === 'https:' || (base.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)))) throw new TypeError('Kernel URL must be an HTTPS origin or loopback HTTP origin');
    if (typeof bearer !== 'string' || !bearer || /[\r\n]/.test(bearer)) throw new TypeError('Bearer required');
    if (!Number.isInteger(timeoutMS) || timeoutMS < 1 || timeoutMS > 30000 || !Number.isInteger(commandTimeoutMS) || commandTimeoutMS < 1 || commandTimeoutMS > 5000) throw new TypeError('Timeout invalid');
    this.#base = base; this.#bearer = bearer; this.#fetch = fetchImpl; this.#timeout = timeoutMS; this.#commandTimeout = commandTimeoutMS;
  }
  async capabilities({ environmentId, schemaSHA256 }) {
    if (!uuid(environmentId) || !SHA256.test(schemaSHA256 ?? '')) throw new TypeError('expected capability identity and schema required');
    const result = await this.#json('/v1/harness/capabilities');
    if (!exact(result, ['protocol_major', 'protocol_minor', 'schema_sha256', 'environment_id', 'operations']) || result.protocol_major !== 1 || result.protocol_minor !== 0 || result.environment_id !== environmentId || result.schema_sha256 !== schemaSHA256 || !Array.isArray(result.operations) || result.operations.length > 100 || new Set(result.operations).size !== result.operations.length || result.operations.some(op => typeof op !== 'string' || !registry.operations.some(entry => entry.name === op))) throw new Error('Invalid or incompatible capabilities');
    return result;
  }
  async dispatch(command) {
    const checked = validateAgainst('command', command);
    if (!checked.valid || command.operation !== 'runtime.dispatch') throw new TypeError('command rejected');
    const body = JSON.stringify(command);
    if (Buffer.byteLength(body) > 1048576) throw new TypeError('command exceeds 1 MiB');
    const result = await this.#json('/v1/harness/commands', { method: 'POST', body }, this.#commandTimeout);
    if (!validReceipt(result) || result.command_id !== command.command_id || result.environment_id !== command.environment_id) throw new Error('Invalid dispatch response');
    return result;
  }
  async receipt(commandId, { environmentId }) {
    if (!uuid(commandId) || !uuid(environmentId)) throw new TypeError('receipt identity invalid');
    const result = await this.#json(`/v1/harness/receipts/${commandId}`);
    if (!validReceipt(result) || result.command_id !== commandId || result.environment_id !== environmentId) throw new Error('Invalid receipt response');
    return result;
  }
  async result(resultRef) {
    if (!uuid(resultRef)) throw new TypeError('resultRef invalid');
    const result = await this.#json(`/v1/harness/results/${resultRef}`);
    if (!validateAgainst('runtimeDispatchResult', result).valid || !uuid(result.receipt_id) || !int(result.revision)) throw new Error('Invalid result response');
    return result;
  }
  async query(operation, input) {
    if (!['runtime.receipt', 'runtime.events'].includes(operation) || !validateOperationInput(operation, input).valid) throw new TypeError('query rejected');
    const result = await this.#json(`/v1/harness/query/${operation}`, { method: 'POST', body: JSON.stringify(input) });
    if (operation === 'runtime.receipt') {
      if (!exact(result, ['receipt_id', 'revision', 'state']) || !uuid(result.receipt_id) || !int(result.revision) || !['accepted', 'pending', 'succeeded', 'failed', 'uncertain'].includes(result.state)) throw new Error('Invalid receipt query response');
    } else {
      if (!exact(result, ['events', 'next_seq']) || !Array.isArray(result.events) || result.events.length > input.limit || !int(result.next_seq)) throw new Error('Invalid events query response');
      let previous = input.after_seq;
      for (const event of result.events) {
        if (!validateAgainst('RuntimeEvent', event).valid || !uuid(event.event_id) || event.thread_id !== input.thread_id || !int(event.seq) || event.seq <= previous || (event.effect_id != null && !uuid(event.effect_id))) throw new Error('Invalid events query response');
        previous = event.seq;
      }
      if (result.next_seq < previous) throw new Error('Invalid events cursor');
    }
    return result;
  }
  async snapshot(threadId, { pageSize = 100, cursor } = {}) {
    if (!uuid(threadId) || !Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) throw new TypeError('threadId or pageSize invalid');
    if (cursor !== undefined && (typeof cursor !== 'string' || Buffer.byteLength(cursor) > 512)) throw new TypeError('cursor invalid');
    const q = new URLSearchParams({ module: 'runtime', page_size: String(pageSize) });
    if (cursor !== undefined) q.set('cursor', cursor);
    const result = await this.#json(`/v1/harness/threads/${threadId}/snapshot?${q}`);
    const data = result?.data;
    if (!validateAgainst('snapshotEnvelope', result).valid || result.module !== 'runtime' || !int(data.revision) || !int(data.as_of_seq) || data.receipts.length + data.effects.length > pageSize || (data.next_cursor !== undefined && Buffer.byteLength(data.next_cursor) > 512)) throw new Error('Invalid snapshot response');
    return result;
  }
  async stream(threadId, afterSeq, { signal } = {}) {
    if (!uuid(threadId) || !int(afterSeq)) throw new TypeError('stream cursor invalid');
    const response = await withDeadline(this.#timeout, signal, scoped => this.#request(`/v1/harness/streams/thread/${threadId}?${new URLSearchParams({ after_seq: String(afterSeq), modules: 'runtime' })}`, { signal: scoped, headers: { accept: 'text/event-stream', 'last-event-id': String(afterSeq) } }));
    if (!/^text\/event-stream(?:\s*;|\s*$)/i.test(response.headers.get('content-type') ?? '')) { void response.body?.cancel(); throw new Error('Invalid stream content type'); }
    return response;
  }
  async payload(payloadRef) {
    if (!uuid(payloadRef)) throw new TypeError('payloadRef invalid');
    const result = await this.#json(`/v1/harness/payloads/${payloadRef}`);
    if (!validateAgainst('runtimeModuleEvent', result).valid) throw new Error('Invalid payload response');
    return result;
  }
  async #json(path, options = {}, timeout = this.#timeout) {
    return withDeadline(timeout, options.signal, async signal => {
      const response = await this.#request(path, { ...options, signal });
      return readJSON(response, MAX_BODY);
    });
  }
  async #request(path, options = {}) {
    const response = await this.#fetch(new URL(path, this.#base), { ...options, redirect: 'error', cache: 'no-store', headers: { authorization: `Bearer ${this.#bearer}`, accept: 'application/json', ...(options.body ? { 'content-type': 'application/json' } : {}), ...options.headers } });
    if (!response.ok) {
      let data; try { data = await readJSON(response, 4096); } catch { throw new Error(`Kernel HTTP ${response.status}`); }
      if (!validateAgainst('harnessError', data).valid) throw new Error(`Invalid Kernel error (HTTP ${response.status})`);
      throw Object.assign(new Error(data.message), data, { status: response.status });
    }
    return response;
  }
}
async function readJSON(response, limit) {
  if (!response.body) throw new Error('Missing response body');
  const reader = response.body.getReader(); const chunks = []; let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > limit) { void reader.cancel().catch(() => {}); throw new Error('Response exceeds limit'); }
      chunks.push(value);
    }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)));
  } finally { reader.releaseLock(); }
}
async function withDeadline(ms, outerSignal, action) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('Kernel deadline exceeded')), ms);
  timer.unref?.();
  const signal = outerSignal ? AbortSignal.any([controller.signal, outerSignal]) : controller.signal;
  let onAbort;
  const expired = new Promise((_, reject) => { onAbort = () => reject(signal.reason); if (signal.aborted) onAbort(); else signal.addEventListener('abort', onAbort, { once: true }); });
  try { return await Promise.race([Promise.resolve().then(() => { signal.throwIfAborted(); return action(signal); }), expired]); }
  finally { clearTimeout(timer); signal.removeEventListener('abort', onAbort); }
}
function validReceipt(value) {
  return validateAgainst('httpCommandReceipt', value).valid && uuid(value.command_id) && uuid(value.receipt_id) && uuid(value.environment_id) && int(value.revision) && (value.result_ref == null || uuid(value.result_ref));
}
