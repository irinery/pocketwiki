import { RuntimeProjection } from './projection.mjs';

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
      this.publish({ available: false, error: error.status === 404 || error.status === 405 ? 'LEGACY_SERVER' : error.code || 'ERR_UNAVAILABLE' });
      throw error;
    }
  }
  async reconnect() {
    const p = new RuntimeProjection({ environmentId: this.environmentId, threadId: this.threadId, confirmedRevision: this.state.revision, confirmedSeq: this.state.lastSeq });
    let cursor;
    do {
      const page = await this.transport.snapshot(this.threadId, { cursor });
      p.appendPage(page, cursor); cursor = page.data.next_cursor;
    } while (cursor != null);
    this.projection = p; this.publishView(p.finish());
  }
  publishView(view) {
    this.publish({ available: true, error: null, revision: view.revision, lastSeq: view.lastSeq, receipts: [...view.receipts.values()] });
  }
  async applyEvent(event) {
    try {
      const payload = event.delivery === 'reference' ? await this.transport.payload(event.payload_ref) : undefined;
      this.projection.bufferEvent(event, payload);
      this.publishView(this.projection.finish());
    } catch (error) {
      this.publish({ available: false, error: error.code || 'ERR_INVALID' });
      throw error;
    }
  }
  async submit(text, commandId = crypto.randomUUID()) {
    if (!this.state.available) throw Object.assign(new Error('Runtime indisponível'), { code: 'ERR_UNAVAILABLE' });
    const command = { protocol_major: 1, command_id: commandId, environment_id: this.environmentId, expected_revision: this.state.revision, operation: 'runtime.dispatch', input: { command_id: commandId, thread_id: this.threadId, expected_revision: this.state.revision, operation: 'submit', text } };
    const receipt = await this.transport.dispatch(command);
    // An acknowledgement is provisional, never an indication of effect completion.
    this.publish({ receipts: [...this.state.receipts.filter(item => item.command_id !== commandId), receipt] });
    return receipt;
  }
}
