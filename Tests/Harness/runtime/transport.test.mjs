import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { RuntimeTransport } from '../../../src/harness/runtime/transport.mjs';

const id = '11111111-1111-4111-8111-111111111111';
const command = { protocol_major: 1, command_id: id, environment_id: id, expected_revision: 0, operation: 'runtime.dispatch', input: { command_id: id, thread_id: id, expected_revision: 0, operation: 'submit', text: 'hello' } };
test('transporte HTTP autentica, valida antes do envio e não repete mutação', async () => {
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push({ method: req.method, url: req.url, auth: req.headers.authorization });
    req.resume();
    res.writeHead(503, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ code: 'ERR_UNAVAILABLE', message: 'unavailable', correlation_id: id, retryable: true }));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    const client = new RuntimeTransport({ baseURL: `http://127.0.0.1:${server.address().port}`, bearer: 'secret' });
    await assert.rejects(client.dispatch({ ...command, input: { ...command.input, expected_revision: 1 } }), /command/);
    assert.equal(requests.length, 0);
    await assert.rejects(client.dispatch(command), e => e.code === 'ERR_UNAVAILABLE' && e.correlation_id === id);
    assert.deepEqual(requests, [{ method: 'POST', url: '/v1/harness/commands', auth: 'Bearer secret' }]);
  } finally { server.close(); }
});

test('snapshot e stream usam rotas R1 e recusam parâmetros inválidos', async () => {
  const urls = [];
  const server = http.createServer((req, res) => { urls.push(req.url); res.writeHead(200, { 'content-type': req.url.includes('/streams/') ? 'text/event-stream' : 'application/json' }); res.end(req.url.includes('/streams/') ? 'id: 1\ndata: {}\n\n' : JSON.stringify({ module: 'runtime', data: { snapshot_id: id, revision: 0, as_of_seq: 0, receipts: [], effects: [] } })); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    const client = new RuntimeTransport({ baseURL: `http://127.0.0.1:${server.address().port}`, bearer: 'secret' });
    await client.snapshot(id, { pageSize: 2, cursor: 'opaque' });
    const stream = await client.stream(id, 3); assert.match(await stream.text(), /id: 1/);
    await assert.rejects(client.snapshot(id, { pageSize: 101 }), /pageSize/);
    assert.deepEqual(urls, [`/v1/harness/threads/${id}/snapshot?module=runtime&page_size=2&cursor=opaque`, `/v1/harness/streams/thread/${id}?after_seq=3&modules=runtime`]);
  } finally { server.close(); }
});
