import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const id = '11111111-1111-4111-8111-111111111111';
test('Swift SSE autentica, valida envelope e propaga erro do Kernel via HTTP real', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'runtime-swift-'));
  const bin = join(dir, 'test');
  const compilation = spawnSync('swiftc', ['-swift-version', '6', 'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift', 'Sources/PocketWikiMac/Models/Harness/HarnessV1.swift', 'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeTransport.swift', 'Tests/Harness/runtime/SwiftStreamLive.swift', '-o', bin], { encoding: 'utf8' });
  assert.equal(compilation.status, 0, compilation.stderr);
  let calls = 0;
  const requests = [];
  let commandBody = '';
  const server = http.createServer((req, res) => {
    calls++; requests.push({ url: req.url, auth: req.headers.authorization, last: req.headers['last-event-id'] });
    if (calls === 23 || calls === 24) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      const envelope = { protocol_major: calls === 23 ? 2 : '2', event_id: id, environment_id: id, thread_id: id, seq: 4, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { entity_type: 'EffectRecord', entity_key: JSON.stringify(id), change: 'delete' } };
      return res.end(`id: 4\ndata: ${JSON.stringify(envelope)}\n\n`);
    }
    if (calls === 21 || calls === 22) { req.resume(); res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ receipt_id: calls === 21 ? id : '00000000-0000-0000-0000-000000000000', revision: 1, state: 'succeeded' })); return; }
    if (calls === 20) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('{'); return; }
    if (calls === 17 || calls === 18 || calls === 19) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      const envelope = { protocol_major: 1, event_id: id, environment_id: id, thread_id: id, seq: 4, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { entity_type: 'EffectRecord', entity_key: JSON.stringify(id), change: 'delete' } };
      const frame = value => `id: ${value.seq}\ndata: ${JSON.stringify(value)}\n\n`;
      if (calls === 19) return res.end([2, 3, 4, 4].map(seq => frame({ ...envelope, seq })).join(''));
      const wire = frame(envelope);
      const size = 262144 + (calls === 18 ? 1 : 0);
      return res.end(':' + 'x'.repeat(size - Buffer.byteLength(wire) - 2) + '\n' + wire);
    }
    if (calls === 13 || calls === 14) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ receipt_id: id, revision: 1, state: calls === 13 ? 'accepted' : 'invented' })); return; }
    if (calls === 15 || calls === 16) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ command_id: id, receipt_id: id, environment_id: id, revision: 1, state: 'succeeded', duplicate: calls === 15 ? false : 'false', result_ref: null })); return; }
    if (calls === 11 || calls === 12) { req.resume(); res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ events: [{ event_id: id, thread_id: calls === 11 ? id : '22222222-2222-4222-8222-222222222222', seq: 1, kind: 'effect_started' }], next_seq: 1 })); return; }
    if (calls === 9 || calls === 10) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ protocol_major: 1, protocol_minor: 0, schema_sha256: (calls === 9 ? 'a' : 'b').repeat(64), environment_id: id, operations: ['runtime.dispatch'] })); return; }
    if (calls === 7 || calls === 8) { res.writeHead(200, { 'Content-Type': 'application/json' }); const data = { snapshot_id: id, revision: 1, as_of_seq: 2, receipts: [], effects: [] }; if (calls === 8) data.next_cursor = null; res.end(JSON.stringify({ module: 'runtime', data })); return; }
    if (calls === 5 || calls === 6) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(calls === 5 ? { entity_type: 'EffectRecord', entity_key: JSON.stringify(id), change: 'delete' } : { unexpected: true })); return; }
    if (calls === 4) { req.on('data', chunk => commandBody += chunk); req.on('end', () => { res.writeHead(202, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ command_id: id, receipt_id: id, environment_id: id, revision: 1, state: 'accepted', duplicate: false })); }); return; }
    if (calls === 3) { res.writeHead(403, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ code: 'ERR_FORBIDDEN', message: 'denied', correlation_id: id, retryable: false })); return; }
    const envelope = { protocol_major: 1, event_id: id, environment_id: id, thread_id: id, seq: 4, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { entity_type: 'EffectRecord', entity_key: JSON.stringify(id), change: 'delete' } };
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(': keepalive\n\n');
    res.end(`id: ${calls === 2 ? 5 : 4}\ndata: ${JSON.stringify(envelope)}\n\n`);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    const child = spawn(bin, [`http://127.0.0.1:${server.address().port}`], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = ''; child.stderr.on('data', data => stderr += data);
    const [exit] = await once(child, 'exit');
    assert.equal(exit, 0, stderr);
    assert.equal(calls, 24);
    assert.deepEqual(requests.slice(0, 3), Array.from({ length: 3 }, () => ({ url: `/v1/harness/streams/thread/${id}?after_seq=3&modules=runtime`, auth: 'Bearer test-secret', last: '3' })));
    assert.equal(requests[3].url, '/v1/harness/commands');
    for (const request of requests.slice(4, 6)) assert.deepEqual(request, { url: `/v1/harness/payloads/${id}`, auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(6, 8)) assert.deepEqual(request, { url: `/v1/harness/threads/${id}/snapshot?module=runtime&page_size=1`, auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(8, 10)) assert.deepEqual(request, { url: '/v1/harness/capabilities', auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(10, 12)) assert.deepEqual(request, { url: '/v1/harness/query/runtime.events', auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(12, 14)) assert.deepEqual(request, { url: `/v1/harness/results/${id}`, auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(14, 16)) assert.deepEqual(request, { url: `/v1/harness/receipts/${id}`, auth: 'Bearer test-secret', last: undefined });
    for (const request of requests.slice(16, 19)) assert.deepEqual(request, { url: `/v1/harness/streams/thread/${id}?after_seq=3&modules=runtime`, auth: 'Bearer test-secret', last: '3' });
    assert.equal(requests[19].url, '/v1/harness/capabilities');
    for (const request of requests.slice(20, 22)) assert.deepEqual(request, { url: '/v1/harness/query/runtime.receipt', auth: 'Bearer test-secret', last: undefined });
    assert.deepEqual(JSON.parse(commandBody), { protocol_major: 1, command_id: id, environment_id: id, expected_revision: 0, operation: 'runtime.dispatch', input: { command_id: id, thread_id: id, expected_revision: 0, operation: 'submit', text: 'Olá' } });
  } finally { server.close(); await rm(dir, { recursive: true, force: true }); }
});
