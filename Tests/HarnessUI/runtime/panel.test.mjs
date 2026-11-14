import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mountRuntimePanel } from '../../../src/harness-ui/runtime/panel.mjs';
class Element {
  constructor() { this.children = []; this.dataset = {}; this.listeners = {}; this.value = ''; }
  setAttribute() {} append(...children) { this.children.push(...children); } replaceChildren(...children) { this.children = children; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
}
test('estado pendente sobrevive a render e erro não expõe detalhes', async () => {
  globalThis.document = { createElement: () => new Element() };
  const root = new Element(); let reject;
  const client = { state: { available: true, receipts: [] }, submit() { return new Promise((_, fail) => { reject = fail; }); } };
  mountRuntimePanel(root, client);
  const [status, form] = root.children; const [input, submit] = form.children;
  input.value = 'rascunho'; const pending = form.listeners.submit({ preventDefault() {} });
  client.state.pendingCommandId = 'id'; client.onChange(client.state);
  assert.equal(submit.disabled, true); assert.equal(input.disabled, true);
  reject(new Error('token supersecreto')); await pending;
  assert.equal(input.value, 'rascunho'); assert.doesNotMatch(status.textContent, /supersecreto/); assert.equal(submit.disabled, true);
  delete globalThis.document;
});
