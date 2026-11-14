import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RuntimeClient } from '../../../src/harness-ui/runtime/client.mjs';
const id = '11111111-1111-4111-8111-111111111111';
test('falha ambígua bloqueia nova intenção até consultar receipt', async () => {
  let calls = 0;
  const transport = { async dispatch() { calls++; throw new Error('secret'); }, async receipt(commandId) { return { command_id: commandId, state: 'accepted' }; } };
  const client = new RuntimeClient({ transport, environmentId: id, threadId: id }); client.state.available = true;
  await assert.rejects(client.submit('a', id));
  await assert.rejects(client.submit('a', '22222222-2222-4222-8222-222222222222'));
  assert.equal(calls, 1); assert.equal(client.state.pendingCommandId, id);
  await client.resolvePending(); assert.equal(client.state.pendingCommandId, undefined); assert.equal(client.state.receipts[0].state, 'accepted');
});
test('reconexão falha desabilita UI', async () => {
  const client = new RuntimeClient({ transport: { async snapshot() { throw new Error('secret'); } }, environmentId: id, threadId: id }); client.state.available = true;
  await assert.rejects(client.reconnect()); assert.equal(client.state.available, false); assert.equal(client.state.error, 'ERR_UNAVAILABLE');
});
test('validação local não deixa intenção pendente', async () => {
  const client = new RuntimeClient({ transport: {}, environmentId: id, threadId: id }); client.state.available = true;
  await assert.rejects(client.submit('', id), { code: 'ERR_INVALID' }); assert.equal(client.pendingCommandId, undefined);
});
test('receipt consultado antigo não substitui evento mais novo', async () => {
  const transport = { async receipt(commandId) { return { command_id: commandId, revision: 1, state: 'accepted' }; } };
  const client = new RuntimeClient({ transport, environmentId: id, threadId: id }); client.pendingCommandId = id;
  client.state.receipts = [{ command_id: id, revision: 3, state: 'succeeded' }];
  await client.resolvePending(); assert.equal(client.state.receipts[0].state, 'succeeded');
});
test('repetição após falha ambígua usa o mesmo envelope', async () => {
  const calls = []; const transport = { async dispatch(command) { calls.push(structuredClone(command)); if (calls.length === 1) throw new Error('timeout'); return { command_id: command.command_id, revision: 1, state: 'accepted' }; } };
  const client = new RuntimeClient({ transport, environmentId: id, threadId: id }); client.state.available = true;
  await assert.rejects(client.submit('oi', id)); await client.retryPending();
  assert.deepEqual(calls[0], calls[1]); assert.equal(client.pendingCommandId, undefined);
});
test('404 legado com corpo não-harness mantém fallback', async () => {
  const client = new RuntimeClient({ transport: { async capabilities() { throw new Error('Invalid Kernel error (HTTP 404)'); } }, environmentId: id, threadId: id });
  await assert.rejects(client.open()); assert.equal(client.state.error, 'LEGACY_SERVER'); assert.equal(client.state.available, false);
});
test('limite de deduplicação inicia resnapshot sem espera', async () => {
  const client = new RuntimeClient({ transport: {}, environmentId: id, threadId: id });
  let reconnected = false;
  client.applyEvent = async () => { throw Object.assign(new Error('limite'), { code: 'ERR_RESYNC_REQUIRED' }); };
  client.reconnect = async () => { reconnected = true; };
  const bytes = new TextEncoder().encode('id: 11\ndata: {"seq":11}\n\n');
  const response = new Response(new ReadableStream({ start(controller) { controller.enqueue(bytes); controller.close(); } }));
  await client.consume(response, new AbortController()); assert.equal(reconnected, true);
});
test('reconexão antiga não publica depois de uma mais nova', async () => {
  const resolvers = []; const transport = { snapshot: () => new Promise(resolve => resolvers.push(resolve)), stream: async () => new Response(new ReadableStream({ start() {} }), { headers: { 'content-type': 'text/event-stream' } }) };
  const client = new RuntimeClient({ transport, environmentId: id, threadId: id });
  const first = client.reconnect(), second = client.reconnect();
  const snapshot = seq => ({ module: 'runtime', data: { snapshot_id: id, revision: seq, as_of_seq: seq, receipts: [], effects: [] } });
  resolvers[1](snapshot(2)); await second; resolvers[0](snapshot(1)); await first;
  assert.equal(client.state.lastSeq, 2); client.close();
});
