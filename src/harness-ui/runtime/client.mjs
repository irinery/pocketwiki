import { RuntimeProjection } from './projection.mjs';
import { runtimeFrames } from './sse.mjs';

// The host owns transport and credentials; this client only holds UI state.
export class RuntimeClient {
  constructor({ transport, environmentId, threadId, schemaSHA256, onChange = () => {} }) {
    Object.assign(this, { transport, environmentId, threadId, schemaSHA256, onChange });
    this.state = { available: false, receipts: [], revision: 0, lastSeq: 0 };
  }
  publish(patch) { this.state = { ...this.state, ...patch }; this.onChange(this.state); }
  async open() {
    try {
      await this.transport.capabilities({ environmentId: this.environmentId, schemaSHA256: this.schemaSHA256 });
      await this.reconnect();
    } catch (error) {
      this.publish({ available: false, error: error.status === 404 || error.status === 405 || /^Kernel HTTP (404|405)$/.test(error.message) ? 'LEGACY_SERVER' : error.code || 'ERR_UNAVAILABLE' });
      throw error;
    }
  }
  async reconnect() {
    this.streamAbort?.abort();
    this.publish({ available: false });
    try { return await this.reconnectChecked(); }
    catch (error) {
      this.publish({ available: false, error: error.code || 'ERR_UNAVAILABLE' });
      throw error;
    }
  }
  async reconnectChecked() {
    const p = new RuntimeProjection({ environmentId: this.environmentId, threadId: this.threadId, confirmedRevision: this.state.revision, confirmedSeq: this.state.lastSeq });
    let cursor;
    do {
      const page = await this.transport.snapshot(this.threadId, { cursor });
      p.appendPage(page, cursor); cursor = page.data.next_cursor;
    } while (cursor != null);
    const view = p.finish();
    const abort = new AbortController(); this.streamAbort = abort;
    const response = await this.transport.stream(this.threadId, view.lastSeq, { signal: abort.signal });
    this.projection = p; this.publishView(view);
    this.streamTask = this.consume(response, abort);
  }
  async consume(response, abort) {
    try {
      for await (const event of runtimeFrames(response)) {
        if (abort.signal.aborted) break;
        await this.applyEvent(event, abort.signal);
      }
      if (!abort.signal.aborted) this.publish({ available: false, error: 'ERR_UNAVAILABLE' });
    } catch (error) {
      if (!abort.signal.aborted) this.publish({ available: false, error: error.code || 'ERR_INVALID' });
    }
  }
  close() { this.streamAbort?.abort(); }

  publishView(view) {
    this.publish({ available: true, error: null, revision: view.revision, lastSeq: view.lastSeq, receipts: [...view.receipts.values()] });
  }
  async applyEvent(event, signal) {
    try {
      const payload = event.delivery === 'reference' ? await this.transport.payload(event.payload_ref) : undefined;
      if (signal?.aborted) return;
      this.projection.bufferEvent(event, payload);
      this.publishView(this.projection.finish());
    } catch (error) {
      if (signal?.aborted) return;
      this.publish({ available: false, error: error.code || 'ERR_INVALID' });
      throw error;
    }
  }
  async submit(text, commandId = crypto.randomUUID()) {
    if (!this.state.available || this.pendingCommandId) throw Object.assign(new Error('Runtime indisponível ou comando pendente'), { code: 'ERR_UNAVAILABLE' });
    const command = { protocol_major: 1, command_id: commandId, environment_id: this.environmentId, expected_revision: this.state.revision, operation: 'runtime.dispatch', input: { command_id: commandId, thread_id: this.threadId, expected_revision: this.state.revision, operation: 'submit', text } };
    this.pendingCommandId = commandId;
    this.publish({ pendingCommandId: commandId });
    let receipt;
    try { receipt = await this.transport.dispatch(command); }
    catch (error) { this.publish({ error: 'ERR_RECEIPT_PENDING' }); throw error; }
    this.pendingCommandId = undefined;
    this.publish({ pendingCommandId: undefined });
    // An acknowledgement is provisional, never an indication of effect completion.
    if (!this.state.receipts.some(item => item.command_id === commandId)) {
      this.publish({ receipts: [...this.state.receipts, receipt] });
    }
    return receipt;
  }
  async resolvePending() {
    if (!this.pendingCommandId) return;
    const receipt = await this.transport.receipt(this.pendingCommandId, { environmentId: this.environmentId });
    this.pendingCommandId = undefined;
    this.publish({ pendingCommandId: undefined, error: null, receipts: [...this.state.receipts.filter(item => item.command_id !== receipt.command_id), receipt] });
    return receipt;
  }
}
