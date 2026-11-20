import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const id = '11111111-1111-4111-8111-111111111111';
function execute(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] }); let output = '';
    const deadline = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`${command} excedeu deadline`)); }, 30000);
    for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output += chunk; });
    child.once('error', reject); child.once('close', code => { clearTimeout(deadline); code === 0 ? resolve(output) : reject(new Error(`${command} exit ${code}: ${output}`)); });
  });
}
test('sessão Swift trata EOF, recusa definitiva e incerteza de rede', { timeout: 180000 }, async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'runtime-session-test-'));
  const binary = path.join(temp, 'session-test');
  try {
    await execute('swiftc', ['-swift-version','6','-parse-as-library',
      'Sources/PocketWikiMac/Models/Harness/HarnessV1.swift',
      'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift',
      'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeTransport.swift',
      'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeProjection.swift',
      'Sources/PocketWikiMac/Views/Harness/Runtime/RuntimeUISession.swift',
      'Tests/HarnessUI/runtime/macos/RuntimeSessionStateTests.swift', '-framework','AppKit','-o',binary]);
    for (const scenario of ['eof', '409', '403', '404', '408', '429', '503', 'disconnect']) {
      const commands = [];
      const server = http.createServer((req, res) => {
        assert.equal(req.headers.authorization, 'Bearer fixture');
        if (req.url === '/v1/harness/capabilities') return res.end(JSON.stringify({ protocol_major: 1, protocol_minor: 0, schema_sha256: 'a'.repeat(64), environment_id: id, operations: ['runtime.dispatch'] }));
        if (req.url.startsWith('/v1/harness/threads/')) return res.end(JSON.stringify({ module: 'runtime', data: { snapshot_id: id, revision: 0, as_of_seq: 0, receipts: [], effects: [] } }));
        if (req.url.startsWith('/v1/harness/streams/')) { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders(); if (scenario === 'eof') res.end(); return; }
        if (req.url === '/v1/harness/commands') {
          const chunks = []; req.on('data', chunk => chunks.push(chunk));
          req.on('end', () => {
            commands.push(JSON.parse(Buffer.concat(chunks).toString('utf8')).command_id);
            if (scenario === 'disconnect') { req.socket.destroy(); return; }
            res.writeHead(Number(scenario), { 'content-type': 'application/json' });
            res.end(JSON.stringify({ code: scenario === '409' ? 'ERR_CONFLICT' : scenario === '403' ? 'ERR_FORBIDDEN' : 'ERR_UNAVAILABLE', message: 'fixture', correlation_id: id, retryable: scenario === '408' || scenario === '429' }));
          }); return;
        }
        res.writeHead(404); res.end();
      });
      server.listen(0, '127.0.0.1'); await once(server, 'listening');
      try {
        await execute(binary, [`http://127.0.0.1:${server.address().port}`, scenario]);
        assert.deepEqual(commands, scenario === 'eof' ? [] : ['409', '403', '404'].includes(scenario) ? ['22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333'] : ['22222222-2222-4222-8222-222222222222'], scenario);
      } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    }
  } finally { await rm(temp, { recursive: true, force: true }); }
});
