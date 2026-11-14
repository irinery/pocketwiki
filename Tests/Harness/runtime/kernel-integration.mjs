import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import http from 'node:http';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { LocalCredentialHost } from '../../../src/harness/local-host.mjs';
import { KernelLocalBootstrapClient } from '../../../src/harness/kernel-bootstrap.mjs';
import { RuntimeTransport } from '../../../src/harness/runtime/transport.mjs';
import { validateAgainst } from '../../../src/harness/contracts/validate.mjs';
import { spawnBeforeDeadline } from './spawn-before-deadline.mjs';

const kernel = process.env.RUNTIME_KERNEL_BINARY;
const swiftClient = process.env.RUNTIME_SWIFT_BINARY;
assert.ok(kernel && swiftClient, 'RUNTIME_KERNEL_BINARY e RUNTIME_SWIFT_BINARY são obrigatórios');
const deadline = AbortSignal.timeout(180_000);
const deadlineFailure = new Promise((_, reject) => deadline.addEventListener('abort', () => reject(new Error('integração excedeu deadline global de 180s')), { once: true }));
const dir = await Promise.race([mkdtemp(path.join('/tmp', 'rt-e1-')), deadlineFailure]);
const socketPath = path.join(dir, 'boot.sock');
const dbPath = path.join(dir, 'runtime.db');
const ioPath = path.join(dir, 'io');
const principal = randomUUID(), environment = randomUUID(), thread = randomUUID(), other = randomUUID();
const audience = 'pocketkernel.harness.v1';
const schemaHash = createHash('sha256').update(await Promise.race([readFile('src/harness/contracts/harness-v1.schema.json'), deadlineFailure])).digest('hex');
const children = [], bootstrapClients = [];
let streamAbort;
const deadlineFetch = (url, options = {}) => fetch(url, { ...options, signal: options.signal ? AbortSignal.any([deadline, options.signal]) : deadline });

try {
  await Promise.race([run(), deadlineFailure]);
} finally {
  streamAbort?.abort();
  closeBootstrapClients();
  for (const child of children) await terminate(child);
  await rm(dir, { recursive: true, force: true });
}

async function run() {
  await mkdir(ioPath);
  let running = await startKernel();
  let base = running.base;
  assert.equal((await stat(socketPath)).mode & 0o777, 0o600);
  await postThread({ environment_id: environment, thread_id: thread, owner_principal_id: principal });
  let bearer = await issue(principal);
  const secondBearer = await issue(principal);
  const wrongBearer = await issue(other);
  let client = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: deadlineFetch });
  const wrongClient = new RuntimeTransport({ baseURL: base, bearer: wrongBearer, fetchImpl: deadlineFetch });
  const capabilities = await client.capabilities({ environmentId: environment, schemaSHA256: schemaHash });
  assert.equal(capabilities.environment_id, environment);
  assert.equal(capabilities.schema_sha256, schemaHash);
  const deniedCommand = command(randomUUID(), 0, 'sem acesso');
  await assert.rejects(wrongClient.dispatch(deniedCommand), error => error.code === 'ERR_FORBIDDEN');
  const deniedEvents = await client.query('runtime.events', { thread_id: thread, after_seq: 0, limit: 100 });
  assert.deepEqual(deniedEvents.events, [], 'negação não pode gravar evento');
  const initial = await client.snapshot(thread, { pageSize: 1 });
  assert.deepEqual(initial.data.receipts, []);
  assert.deepEqual(initial.data.effects, []);
  streamAbort = new AbortController();
  const response = await client.stream(thread, initial.data.as_of_seq, { signal: streamAbort.signal });
  let events = streamEvents(response, streamAbort.signal)[Symbol.asyncIterator]();
  const firstID = randomUUID(), firstCommand = command(firstID, initial.data.revision, 'efeito real 1');
  let arrivals = 0, release;
  const readyTogether = new Promise(resolve => { release = resolve; });
  const concurrentFetch = async (url, options) => {
    if (++arrivals === 2) release();
    await Promise.race([readyTogether, deadlineFailure]);
    return deadlineFetch(url, options);
  };
  const raceClient1 = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: concurrentFetch });
  const raceClient2 = new RuntimeTransport({ baseURL: base, bearer: secondBearer, fetchImpl: concurrentFetch });
  const receipts = await Promise.all([raceClient1.dispatch(firstCommand), raceClient2.dispatch(firstCommand)]);
  assert.equal(arrivals, 2);
  assert.deepEqual(receipts.map(receipt => receipt.duplicate).sort(), [false, true]);
  assert.equal(receipts[0].receipt_id, receipts[1].receipt_id);
  const first = receipts.find(receipt => !receipt.duplicate);
  assert.equal(first.command_id, firstID);
  await waitForEffect(events, firstID);
  const firstReceipt = await client.receipt(firstID, { environmentId: environment });
  assert.equal(firstReceipt.state, 'succeeded');
  assert.ok(firstReceipt.result_ref);
  const typedResult = await client.result(firstReceipt.result_ref);
  assert.equal(typedResult.receipt_id, first.receipt_id);
  // Reopen the same durable store in a fresh Kernel process and bootstrap a fresh owner.
  streamAbort.abort();
  closeBootstrapClients();
  await terminate(running.child);
  running = await startKernel(); base = running.base;
  const staleClient = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: deadlineFetch });
  await assert.rejects(staleClient.receipt(firstID, { environmentId: environment }), error => error.code === 'ERR_FORBIDDEN');
  bearer = await issue(principal);
  client = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: deadlineFetch });
  const reopenedReceipt = await client.receipt(firstID, { environmentId: environment });
  assert.equal(reopenedReceipt.receipt_id, first.receipt_id);
  assert.equal(reopenedReceipt.state, 'succeeded');
  assert.equal(reopenedReceipt.revision, firstReceipt.revision);
  assert.equal((await readdir(path.join(ioPath, 'effects'))).length, 1);
  const page1 = await client.snapshot(thread, { pageSize: 1 });
  streamAbort = new AbortController();
  const reopenedStream = await client.stream(thread, page1.data.as_of_seq, { signal: streamAbort.signal });
  events = streamEvents(reopenedStream, streamAbort.signal)[Symbol.asyncIterator]();
  assert.ok(page1.data.next_cursor, 'duas entidades exigem paginação');
  const secondID = randomUUID();
  const swift = await startSwift(base, bearer, firstID, secondID);
  const second = await client.dispatch(command(secondID, page1.data.revision, 'efeito real 2'));
  assert.equal(second.duplicate, false);
  const page2 = await client.snapshot(thread, { pageSize: 1, cursor: page1.data.next_cursor });
  for (const key of ['snapshot_id', 'revision', 'as_of_seq']) assert.equal(page2.data[key], page1.data[key]);
  assert.equal(page2.data.next_cursor, undefined);
  const oldReceipts = [...page1.data.receipts, ...page2.data.receipts];
  assert.deepEqual(oldReceipts.map(value => value.command_id), [firstID], 'snapshot congelado não incorpora comando concorrente');
  assert.equal(page1.data.effects.length + page2.data.effects.length, 1);
  const buffered = [];
  const secondEffect = await waitForEffect(events, secondID, buffered);
  assert.ok(secondEffect.seq > page1.data.as_of_seq);
  const duplicate = await client.dispatch(firstCommand);
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.receipt_id, first.receipt_id);
  await assert.rejects(client.dispatch({ ...firstCommand, input: { ...firstCommand.input, text: 'outro conteúdo' } }), error => error.code === 'ERR_CONFLICT');
  assert.equal((await readdir(path.join(ioPath, 'effects'))).length, 2, 'sem efeito extra por negação ou duplicação');
  await finishSwift(swift, buffered);

  // A process-level crash occurs after the real file is synced but before acknowledgement.
  streamAbort.abort(); closeBootstrapClients(); await terminate(running.child);
  running = await startKernel({ pauseAfterEffect: true }); base = running.base;
  bearer = await issue(principal);
  client = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: deadlineFetch });
  const beforeCrash = await client.snapshot(thread, { pageSize: 100 });
  const crashID = randomUUID();
  await client.dispatch(command(crashID, beforeCrash.data.revision, 'efeito interrompido'));
  const interruptedEffect = await running.barrier;
  const effectPath = path.join(ioPath, 'effects', `${interruptedEffect}.json`);
  const effectBytes = await readFile(effectPath);
  const effectStat = await stat(effectPath);
  const eventsBeforeCrash = await client.query('runtime.events', { thread_id: thread, after_seq: 0, limit: 100 });
  assert.equal(eventsBeforeCrash.events.filter(event => event.effect_id === interruptedEffect && event.kind === 'effect_started').length, 1);
  assert.equal(eventsBeforeCrash.events.filter(event => event.effect_id === interruptedEffect && event.kind === 'effect_finished').length, 0);
  const killed = once(running.child, 'exit');
  assert.equal(running.child.kill('SIGKILL'), true);
  const [, crashSignal] = await killed;
  assert.equal(crashSignal, 'SIGKILL');
  closeBootstrapClients();
  running = await startKernel(); base = running.base;
  assert.equal(running.drainedCount, 0, 'recovery não pode repetir efeito no drain inicial');
  bearer = await issue(principal);
  client = new RuntimeTransport({ baseURL: base, bearer, fetchImpl: deadlineFetch });
  const uncertain = await client.receipt(crashID, { environmentId: environment });
  assert.equal(uncertain.state, 'uncertain');
  streamAbort = new AbortController();
  const recoveredStream = await client.stream(thread, beforeCrash.data.as_of_seq, { signal: streamAbort.signal });
  events = streamEvents(recoveredStream, streamAbort.signal)[Symbol.asyncIterator]();
  await waitForUncertain(events, interruptedEffect);
  const recoveredEvents = await client.query('runtime.events', { thread_id: thread, after_seq: 0, limit: 100 });
  assert.equal(recoveredEvents.events.filter(event => event.effect_id === interruptedEffect && event.kind === 'effect_started').length, 1);
  assert.equal(recoveredEvents.events.filter(event => event.effect_id === interruptedEffect && event.kind === 'effect_uncertain').length, 1);
  assert.equal(recoveredEvents.events.filter(event => event.effect_id === interruptedEffect && event.kind === 'effect_finished').length, 0);
  assert.deepEqual(await readFile(effectPath), effectBytes);
  const recoveredStat = await stat(effectPath);
  assert.equal(recoveredStat.ino, effectStat.ino);
  assert.equal(recoveredStat.mtimeMs, effectStat.mtimeMs);
  assert.equal((await readdir(path.join(ioPath, 'effects'))).length, 3);
  if (process.env.RUNTIME_EVIDENCE_PATH) {
    await writeFile(process.env.RUNTIME_EVIDENCE_PATH, JSON.stringify({ receipts: [firstReceipt, reopenedReceipt, uncertain], events_before_crash: eventsBeforeCrash.events, events_after_recovery: recoveredEvents.events }, null, 2) + '\n');
  }
  console.log('Kernel real: bootstrap E0, autorização, dispatch, recuperação, efeito, receipt, snapshot MVCC, SSE e clientes JS/Swift verificados');
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
    const req = http.request({ socketPath, path: '/v1/runtime/threads', method: 'POST', signal: deadline, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } }, res => { res.resume(); res.once('end', () => resolve(res.statusCode)); });
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
async function waitForEffect(events, commandID, buffered = []) {
  const deadline = setTimeout(() => streamAbort.abort(), 15000);
  try {
    for (;;) {
      const { value, done } = await events.next();
      assert.equal(done, false, 'SSE terminou antes do efeito');
      buffered.push(value);
      if (value.payload?.entity_type === 'EffectRecord' && value.payload.value?.command_id === commandID && value.payload.value.state === 'succeeded') return value;
    }
  } finally { clearTimeout(deadline); }
}
async function waitForUncertain(events, effectID) {
  for (;;) {
    const { value, done } = await events.next();
    assert.equal(done, false, 'SSE terminou antes de effect_uncertain');
    if (value.payload?.entity_type === 'RuntimeEvent' && value.payload.value?.effect_id === effectID && value.payload.value.kind === 'effect_uncertain') return;
  }
}
async function startSwift(base, bearer, commandID, secondID) {
  const child = spawnBeforeDeadline(deadline, swiftClient, [base, environment, thread, commandID, schemaHash, secondID], { stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child); let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk.toString(); });
  const lines = createInterface({ input: child.stdout });
  child.stdin.write(`${bearer}\n`);
  const firstLine = once(lines, 'line').then(([line]) => line);
  const prematureExit = once(child, 'exit').then(([code]) => { throw new Error(`cliente Swift terminou antes de PAGE1: ${code}; ${stderr}`); });
  assert.equal(await Promise.race([firstLine, prematureExit]), 'PAGE1');
  return { child, lines, stderr: () => stderr };
}
async function finishSwift(swift, events) {
  swift.child.stdin.end(`${JSON.stringify(events.map(event => Buffer.from(JSON.stringify(event)).toString('base64')))}\n`);
  const [code] = await once(swift.child, 'exit');
  assert.equal(code, 0, `cliente Swift falhou: ${swift.stderr()}`);
  swift.lines.close();
}
function closeBootstrapClients() {
  for (const bootstrap of bootstrapClients.splice(0)) bootstrap.close();
}
async function startKernel({ pauseAfterEffect = false } = {}) {
  const args = ['-mode', 'serve', '-mock-model', '-addr', '127.0.0.1:0', '-harness-rig-ready', '-harness-db', dbPath, '-harness-auth-store', path.join(dir, 'auth.json'), '-harness-bootstrap-socket', socketPath, '-harness-temp-root', ioPath, '-harness-audience', audience, '-harness-schema-sha256', schemaHash];
  if (pauseAfterEffect) args.push('-harness-rig-pause-after-effect');
  const child = spawnBeforeDeadline(deadline, kernel, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  let resolveBarrier, resolveDrain, rejectDrain;
  const barrier = new Promise(resolve => { resolveBarrier = resolve; });
  const drained = new Promise((resolve, reject) => { resolveDrain = resolve; rejectDrain = reject; });
  drained.catch(() => {});
  let logs = '';
  const ready = new Promise((resolve, reject) => {
    const onLine = line => {
      logs = (logs + line + '\n').slice(-16384);
      const marker = /^HARNESS_RIG_EFFECT_WRITTEN ([0-9a-f-]+)$/.exec(line);
      if (marker) resolveBarrier(marker[1]);
      const drain = /^HARNESS_RIG_DRAINED ([0-9]+)$/.exec(line);
      if (drain) resolveDrain(Number(drain[1]));
      if (line.startsWith('HARNESS_RIG_DRAIN_FAILED')) rejectDrain(new Error('Kernel falhou no drain inicial'));
      const match = /^HARNESS_READY (127\.0\.0\.1:[0-9]+)$/.exec(line);
      if (match) resolve(`http://${match[1]}`);
    };
    for (const input of [child.stdout, child.stderr]) createInterface({ input }).on('line', onLine);
    child.once('error', reject);
    child.once('exit', code => {
      const error = new Error(`Kernel terminou antes do READY/DRAINED (${code}): ${logs}`);
      reject(error); rejectDrain(error);
    });
  });
  const base = await ready;
  return { child, base, barrier, drainedCount: await drained };
}
async function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit'); child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 2000);
  try { await exited; } finally { clearTimeout(timer); }
}
