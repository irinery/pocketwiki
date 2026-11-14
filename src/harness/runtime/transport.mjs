import { validateAgainst, validateOperationInput } from '../contracts/validate.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const int = n => Number.isSafeInteger(n) && n >= 0;
const uuid = value => typeof value === 'string' && UUID.test(value);

/** HTTP boundary only: Kernel owns authorization, ledger, and recovery. */
export class RuntimeTransport {
  #base; #bearer; #fetch;
  constructor({ baseURL, bearer, fetchImpl = fetch }) {
    const base = new URL(baseURL);
    if (base.username || base.password || base.search || base.hash || base.pathname !== '/' || !(base.protocol === 'https:' || (base.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname)))) throw new TypeError('Kernel URL must be an HTTPS origin or loopback HTTP origin');
    if (typeof bearer !== 'string' || !bearer || /[\r\n]/.test(bearer)) throw new TypeError('Bearer required');
    this.#base = base; this.#bearer = bearer; this.#fetch = fetchImpl;
  }
  capabilities() { return this.#json('/v1/harness/capabilities'); }
  async dispatch(command) {
    const checked = validateAgainst('command', command);
    if (!checked.valid || command.operation !== 'runtime.dispatch') throw new TypeError('command rejected');
    const body = JSON.stringify(command);
    if (Buffer.byteLength(body) > 1048576) throw new TypeError('command exceeds 1 MiB');
    const result = await this.#json('/v1/harness/commands', { method: 'POST', body });
    if (!validReceipt(result)) throw new Error('Invalid dispatch response');
    return result;
  }
  async receipt(commandId) { if (!uuid(commandId)) throw new TypeError('commandId invalid'); const result = await this.#json(`/v1/harness/receipts/${commandId}`); if (!validReceipt(result)) throw new Error('Invalid receipt response'); return result; }
  result(resultRef) { if (!uuid(resultRef)) throw new TypeError('resultRef invalid'); return this.#json(`/v1/harness/results/${resultRef}`); }
  query(operation, input) {
    if (!['runtime.receipt', 'runtime.events'].includes(operation) || !validateOperationInput(operation, input).valid) throw new TypeError('query rejected');
    return this.#json(`/v1/harness/query/${operation}`, { method: 'POST', body: JSON.stringify(input) });
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
  stream(threadId, afterSeq, { signal } = {}) {
    if (!uuid(threadId) || !int(afterSeq)) throw new TypeError('stream cursor invalid');
    return this.#request(`/v1/harness/streams/thread/${threadId}?${new URLSearchParams({ after_seq: String(afterSeq), modules: 'runtime' })}`, { signal, headers: { accept: 'text/event-stream', 'last-event-id': String(afterSeq) } });
  }
  payload(payloadRef) { if (!uuid(payloadRef)) throw new TypeError('payloadRef invalid'); return this.#json(`/v1/harness/payloads/${payloadRef}`); }
  async #json(path, options = {}) { const response = await this.#request(path, options); return response.json(); }
  async #request(path, options = {}) {
    const response = await this.#fetch(new URL(path, this.#base), { ...options, redirect: 'error', cache: 'no-store', headers: { authorization: `Bearer ${this.#bearer}`, accept: 'application/json', ...(options.body ? { 'content-type': 'application/json' } : {}), ...options.headers } });
    if (!response.ok) {
      let data; try { data = await response.json(); } catch { throw new Error(`Kernel HTTP ${response.status}`); }
      if (!validateAgainst('harnessError', data).valid) throw new Error(`Invalid Kernel error (HTTP ${response.status})`);
      throw Object.assign(new Error(data.message), data, { status: response.status });
    }
    return response;
  }
}

function validReceipt(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const keys = ['command_id', 'receipt_id', 'environment_id', 'revision', 'state', 'duplicate', 'result_ref'];
  return Object.keys(value).every(key => keys.includes(key)) && uuid(value.command_id) && uuid(value.receipt_id) && uuid(value.environment_id) && int(value.revision) && ['accepted', 'pending', 'succeeded', 'failed', 'uncertain'].includes(value.state) && typeof value.duplicate === 'boolean' && (value.result_ref === undefined || value.result_ref === null || uuid(value.result_ref));
}
