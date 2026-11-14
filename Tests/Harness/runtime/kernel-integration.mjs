import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, readdir, rm, stat } from 'node:fs/promises';
import { LocalCredentialHost } from '../../../src/harness/local-host.mjs';
import { KernelLocalBootstrapClient } from '../../../src/harness/kernel-bootstrap.mjs';
import { RuntimeTransport } from '../../../src/harness/runtime/transport.mjs';
import { validateAgainst } from '../../../src/harness/contracts/validate.mjs';

const kernel = process.env.RUNTIME_KERNEL_BINARY;
const swiftClient = process.env.RUNTIME_SWIFT_BINARY;
assert.ok(kernel && swiftClient, 'RUNTIME_KERNEL_BINARY e RUNTIME_SWIFT_BINARY são obrigatórios');
const dir = await mkdtemp(path.join(os.tmpdir(), 'rt-e1-'));
const socketPath = path.join(dir, 'boot.sock');
const dbPath = path.join(dir, 'runtime.db');
const ioPath = path.join(dir, 'io');
const principal = randomUUID(), environment = randomUUID(), thread = randomUUID(), other = randomUUID();
const audience = 'pocketkernel.harness.v1';
const schemaHash = createHash('sha256').update(await readFile('src/harness/contracts/harness-v1.schema.json')).digest('hex');
const children = [], bootstrapClients = [];
let streamAbort;

try {
  await mkdir(ioPath);
  const port = await availablePort();
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(kernel, ['-mode', 'serve', '-mock-model', '-addr', `127.0.0.1:${port}`, '-harness-db', dbPath, '-harness-auth-store', path.join(dir, 'auth.json'), '-harness-bootstrap-socket', socketPath, '-harness-temp-root', ioPath, '-harness-audience', audience, '-harness-schema-sha256', schemaHash], { stdio: ['ignore', 'ignore', 'pipe'] });
  children.push(child);
  let logs = '';
  child.stderr.on('data', chunk => { logs += chunk.toString(); });
  await until(async () => { if (child.exitCode !== null) throw new Error(`Kernel terminou antes de iniciar: ${child.exitCode}; ${logs}`); try { return (await stat(socketPath)).isSocket(); } catch { return false; } }, 'bootstrap socket');
  assert.equal((await stat(socketPath)).mode & 0o777, 0o600);
  await postThread({ environment_id: environment, thread_id: thread, owner_principal_id: principal });
  const bearer = await issue(principal);
  const wrongBearer = await issue(other);
  const client = new RuntimeTransport({ baseURL: base, bearer });
  const wrongClient = new RuntimeTransport({ baseURL: base, bearer: wrongBearer });
  await until(async () => { try { const capabilities = await client.capabilities(); return capabilities.environment_id === environment && capabilities.schema_sha256 === schemaHash; } catch (error) { if (error.cause?.code === 'ECONNREFUSED') return false; throw error; } }, 'HTTP capabilities');
  const deniedCommand = command(randomUUID(), 0, 'sem acesso');
  await assert.rejects(wrongClient.dispatch(deniedCommand), error => error.code === 'ERR_FORBIDDEN');
  const initial = await client.snapshot(thread, { pageSize: 1 });
  assert.deepEqual(initial.data.receipts, []);
  assert.deepEqual(initial.data.effects, []);
  streamAbort = new AbortController();
  const response = await client.stream(thread, initial.data.as_of_seq, { signal: streamAbort.signal });
  const events = streamEvents(response, streamAbort.signal)[Symbol.asyncIterator]();
  const firstID = randomUUID(), firstCommand = command(firstID, initial.data.revision, 'efeito real 1');
  const first = await client.dispatch(firstCommand);
  assert.equal(first.command_id, firstID);
  assert.equal(first.duplicate, false);
  await waitForEffect(events, firstID);
  const firstReceipt = await client.receipt(firstID);
  assert.equal(firstReceipt.state, 'succeeded');
  assert.ok(firstReceipt.result_ref);
  const typedResult = await client.result(firstReceipt.result_ref);
  assert.equal(typedResult.receipt_id, first.receipt_id);
  const page1 = await client.snapshot(thread, { pageSize: 1 });
  assert.ok(page1.data.next_cursor, 'duas entidades exigem paginação');
  const secondID = randomUUID(), second = await client.dispatch(command(secondID, page1.data.revision, 'efeito real 2'));
  assert.equal(second.duplicate, false);
  const page2 = await client.snapshot(thread, { pageSize: 1, cursor: page1.data.next_cursor });
  for (const key of ['snapshot_id', 'revision', 'as_of_seq']) assert.equal(page2.data[key], page1.data[key]);
  assert.equal(page2.data.next_cursor, undefined);
  const oldReceipts = [...page1.data.receipts, ...page2.data.receipts];
  assert.deepEqual(oldReceipts.map(value => value.command_id), [firstID], 'snapshot congelado não incorpora comando concorrente');
  assert.equal(page1.data.effects.length + page2.data.effects.length, 1);
  const secondEffect = await waitForEffect(events, secondID);
  assert.ok(secondEffect.seq > page1.data.as_of_seq);
  const duplicate = await client.dispatch(firstCommand);
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.receipt_id, first.receipt_id);
  await assert.rejects(client.dispatch({ ...firstCommand, input: { ...firstCommand.input, text: 'outro conteúdo' } }), error => error.code === 'ERR_CONFLICT');
  assert.equal((await readdir(path.join(ioPath, 'effects'))).length, 2, 'sem efeito extra por negação ou duplicação');
  await runSwift(base, bearer, firstID);
  console.log('Kernel real: bootstrap E0, autorização, dispatch, efeito, receipt, snapshot MVCC, SSE e clientes JS/Swift verificados');
} finally {
  streamAbort?.abort();
  for (const bootstrap of bootstrapClients) bootstrap.close();
  for (const child of children) await terminate(child);
  await rm(dir, { recursive: true, force: true });
}

function command(commandID, revision, text) {
  return { protocol_major: 1, command_id: commandID, environment_id: environment, expected_revision: revision, operation: 'runtime.dispatch', input: { command_id: commandID, thread_id: thread, expected_revision: revision, operation: 'submit', text } };
}
async function issue(principalId) {
  const bootstrap = new KernelLocalBootstrapClient({ socketPath }); bootstrapClients.push(bootstrap);
  const scopes = ['read', 'submit'];
  await bootstrap.registerAggregateGrant({ principal_id: principalId, environment_id: environment, audience, aggregate_id: thread, scopes });
  let bearer;
  const host = new LocalCredentialHost({ principalId, environmentId: environment, audience, grantedScopes: scopes, deliverBearer: async value => { bearer = value.bearer; }, persistVerifier: verifier => bootstrap.persistVerifier(verifier) });
  await host.bootstrap(scopes, { aggregateId: thread });
  return bearer;
}
async function postThread(body) {
  const payload = JSON.stringify(body);
  const status = await new Promise((resolve, reject) => {
    const req = http.request({ socketPath, path: '/v1/runtime/threads', method: 'POST', headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } }, res => { res.resume(); res.once('end', () => resolve(res.statusCode)); });
    req.once('error', reject); req.end(payload);
  });
  assert.equal(status, 204);
}
async function* streamEvents(response, signal) {
  const reader = response.body.getReader(); const decoder = new TextDecoder(); let pending = '', previous = 0;
  try {
    while (!signal.aborted) {
      const { value, done } = await reader.read(); if (done) break;
      pending += decoder.decode(value, { stream: true });
      assert.ok(Buffer.byteLength(pending) <= 1024 * 1024, 'SSE buffer excedeu limite');
      for (;;) {
        const at = pending.indexOf('\n\n'); if (at < 0) break;
        const frame = pending.slice(0, at); pending = pending.slice(at + 2);
        const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (!data) continue;
        const id = frame.split('\n').find(line => line.startsWith('id:'))?.slice(3).trim();
        const event = JSON.parse(data);
        assert.equal(validateAgainst('streamEnvelope', event).valid, true);
        assert.equal(String(event.seq), id);
        assert.ok(event.seq > previous); previous = event.seq;
        assert.equal(event.environment_id, environment); assert.equal(event.thread_id, thread);
        yield event;
      }
    }
  } finally { await reader.cancel().catch(() => {}); }
}
async function waitForEffect(events, commandID) {
  const deadline = setTimeout(() => streamAbort.abort(), 15000);
  try {
    for (;;) {
      const { value, done } = await events.next();
      assert.equal(done, false, 'SSE terminou antes do efeito');
      if (value.payload?.entity_type === 'EffectRecord' && value.payload.value?.command_id === commandID && value.payload.value.state === 'succeeded') return value;
    }
  } finally { clearTimeout(deadline); }
}
async function runSwift(base, bearer, commandID) {
  const child = spawn(swiftClient, [base, environment, thread, commandID, schemaHash], { stdio: ['pipe', 'ignore', 'pipe'] });
  children.push(child); let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk.toString(); });
  child.stdin.end(`${bearer}\n`);
  const timer = setTimeout(() => child.kill('SIGKILL'), 15000);
  try { const [code] = await once(child, 'exit'); assert.equal(code, 0, `cliente Swift falhou: ${stderr}`); } finally { clearTimeout(timer); }
}
async function availablePort() {
  const server = net.createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port; await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())); return port;
}
async function until(check, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) { if (await check()) return; await new Promise(resolve => setTimeout(resolve, 25)); }
  throw new Error(`timeout aguardando ${label}`);
}
async function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit'); child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 2000);
  try { await exited; } finally { clearTimeout(timer); }
}
