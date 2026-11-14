import { RuntimeProjection } from './projection.mjs';
import { runtimeFrames } from './sse.mjs';
import { validateAgainst } from '../../harness/contracts/validate.mjs';

// The host owns transport and credentials; this client only holds UI state.
export class RuntimeClient {
  constructor({ transport, environmentId, threadId, schemaSHA256, onChange = () => {}, newCommandId = () => crypto.randomUUID() }) {
    Object.assign(this, { transport, environmentId, threadId, schemaSHA256, onChange, newCommandId });
    this.state = { available: false, receipts: [], revision: 0, lastSeq: 0 };
  }
  publish(patch) { this.state = { ...this.state, ...patch }; this.onChange(this.state); }
  async open() {
    try {
      await this.transport.capabilities({ environmentId: this.environmentId, schemaSHA256: this.schemaSHA256 });
      await this.reconnect();
    } catch (error) {
      this.publish({ available: false, error: error.status === 404 || error.status === 405 || /^(?:Kernel HTTP (?:404|405)|Invalid Kernel error \(HTTP (?:404|405)\))$/.test(error.message) ? 'LEGACY_SERVER' : error.code || 'ERR_UNAVAILABLE' });
      throw error;
    }
  }
  async reconnect() {
    this.streamAbort?.abort();
    const generation = this.generation = (this.generation || 0) + 1;
    this.publish({ available: false });
    try { return await this.reconnectChecked(generation); }
    catch (error) {
      if (generation === this.generation) this.publish({ available: false, error: error.code || 'ERR_UNAVAILABLE' });
      throw error;
    }
  }
  async reconnectChecked(generation) {
    const p = new RuntimeProjection({ environmentId: this.environmentId, threadId: this.threadId, confirmedRevision: this.state.revision, confirmedSeq: this.state.lastSeq });
    let cursor;
    do {
      const page = await this.transport.snapshot(this.threadId, { cursor });
      if (generation !== this.generation) return;
      p.appendPage(page, cursor); cursor = page.data.next_cursor;
    } while (cursor != null);
    const view = p.finish();
    const abort = new AbortController(); this.streamAbort = abort;
    const response = await this.transport.stream(this.threadId, view.lastSeq, { signal: abort.signal });
    if (generation !== this.generation) { abort.abort(); return; }
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
      if (!abort.signal.aborted && error.code === 'ERR_RESYNC_REQUIRED') {
        try { await this.reconnect(); } catch {}
      } else if (!abort.signal.aborted) this.publish({ available: false, error: error.code || 'ERR_INVALID' });
    }
  }
  close() { this.generation = (this.generation || 0) + 1; this.streamAbort?.abort(); }

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
  async submit(text, commandId = this.newCommandId()) {
    if (!this.state.available || this.pendingCommandId || this.pendingBusy) throw Object.assign(new Error('Runtime indisponível ou comando pendente'), { code: 'ERR_UNAVAILABLE' });
    const command = { protocol_major: 1, command_id: commandId, environment_id: this.environmentId, expected_revision: this.state.revision, operation: 'runtime.dispatch', input: { command_id: commandId, thread_id: this.threadId, expected_revision: this.state.revision, operation: 'submit', text } };
    if (!validateAgainst('command', command).valid) throw Object.assign(new Error('Comando inválido'), { code: 'ERR_INVALID' });
    this.pendingCommandId = commandId; this.pendingCommand = command; this.pendingBusy = true;
    this.publish({ pendingCommandId: commandId, pendingBusy: true });
    let receipt;
    try { receipt = await this.transport.dispatch(command); }
    catch (error) {
      if (this.pendingCommandId !== commandId) throw error;
      if (error.status >= 400 && error.status < 500 && error.status !== 408 && error.status !== 429) {
        this.pendingCommandId = undefined; this.pendingCommand = undefined; this.publish({ pendingCommandId: undefined });
      } else this.publish({ error: 'ERR_RECEIPT_PENDING' });
      throw error;
    }
    finally { this.pendingBusy = false; this.publish({ pendingBusy: false }); }
    if (this.pendingCommandId !== commandId) return receipt;
    this.pendingCommandId = undefined; this.pendingCommand = undefined;
    this.publish({ pendingCommandId: undefined });
    // An acknowledgement is provisional, never an indication of effect completion.
    if (!this.state.receipts.some(item => item.command_id === commandId)) {
      this.publish({ receipts: [...this.state.receipts, receipt] });
    }
    return receipt;
  }
  async retryPending() {
    if (!this.pendingCommand || this.pendingBusy) return;
    const command = this.pendingCommand, id = this.pendingCommandId;
    this.pendingBusy = true; this.publish({ pendingBusy: true });
    try {
      const receipt = await this.transport.dispatch(command);
      if (this.pendingCommandId !== id) return receipt;
      this.pendingCommandId = undefined; this.pendingCommand = undefined;
      const existing = this.state.receipts.find(item => item.command_id === receipt.command_id);
      this.publish({ pendingCommandId: undefined, error: null, receipts: [...this.state.receipts.filter(item => item.command_id !== receipt.command_id), existing && existing.revision >= receipt.revision ? existing : receipt] });
      return receipt;
    } finally { this.pendingBusy = false; this.publish({ pendingBusy: false }); }
  }
  async resolvePending() {
    if (!this.pendingCommandId || this.pendingBusy) return;
    const id = this.pendingCommandId;
    this.pendingBusy = true; this.publish({ pendingBusy: true });
    try {
      const receipt = await this.transport.receipt(id, { environmentId: this.environmentId });
      if (this.pendingCommandId !== id) return receipt;
      this.pendingCommandId = undefined; this.pendingCommand = undefined;
      const existing = this.state.receipts.find(item => item.command_id === receipt.command_id);
      const value = existing && existing.revision >= receipt.revision ? existing : receipt;
      this.publish({ pendingCommandId: undefined, error: null, receipts: [...this.state.receipts.filter(item => item.command_id !== receipt.command_id), value] });
      return receipt;
    } finally { this.pendingBusy = false; this.publish({ pendingBusy: false }); }
  }
}
