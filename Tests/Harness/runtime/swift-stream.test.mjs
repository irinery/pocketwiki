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
    if (calls === 4) { req.on('data', chunk => commandBody += chunk); req.on('end', () => { res.writeHead(202, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ revision: 1 })); }); return; }
    if (calls === 3) { res.writeHead(403, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ code: 'ERR_FORBIDDEN', message: 'denied', correlation_id: id, retryable: false })); return; }
    const envelope = { protocol_major: 1, event_id: id, environment_id: id, thread_id: id, seq: 4, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { kind: 'effect_finished' } };
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
    assert.equal(calls, 4);
    assert.deepEqual(requests.slice(0, 3), Array.from({ length: 3 }, () => ({ url: `/v1/harness/streams/thread/${id}?after_seq=3&modules=runtime`, auth: 'Bearer test-secret', last: '3' })));
    assert.equal(requests[3].url, '/v1/harness/commands');
    assert.deepEqual(JSON.parse(commandBody), { protocol_major: 1, command_id: id, environment_id: id, expected_revision: 0, operation: 'runtime.dispatch', input: { command_id: id, thread_id: id, expected_revision: 0, operation: 'submit', text: 'Olá' } });
  } finally { server.close(); await rm(dir, { recursive: true, force: true }); }
});
