import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { mkdtemp, readFile, rename, rm, stat } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LOCAL_CREDENTIAL_TTL_MS } from '../src/harness/local-host.mjs';

const binary = process.argv[2];
assert.ok(binary, 'pass the compiled PocketKernel auth probe path');
const temp = await mkdtemp(path.join(os.tmpdir(), 'nh00-auth-'));
const socketPath = path.join(temp, 'kernel-bootstrap.sock');
const storePath = path.join(temp, 'kernel-auth.json');
const ids = {
  principal: '11111111-1111-4111-8111-111111111111',
  otherPrincipal: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  environment: '22222222-2222-4222-8222-222222222222',
  otherEnvironment: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  aggregate: '33333333-3333-4333-8333-333333333333',
  otherAggregate: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
};
const audience = 'pocketkernel.harness';
const children = [];
const kernelLogBuffers = [];
let hostWorker;
let secondHost;
let proxy;
const proxySockets = new Set();

try {
  let kernel = await startKernel();
  hostWorker = await startHostWorker();
  const socketStat = await stat(socketPath);
  assert.equal(socketStat.mode & 0o777, 0o600, 'private bootstrap socket permissions');
  const valid = await issue({
    principalId: ids.principal, environmentId: ids.environment, audience,
    aggregateId: ids.aggregate, grantScopes: ['read'], requestedScopes: ['read'], grantedScopes: ['read', 'execute']
  });
  const validBearer = valid.bearer;
  assert.match(validBearer, /^[A-Za-z0-9_-]{43}$/);
  await assertRequest(kernel.http, validBearer, ids.aggregate, 'read', 200);

  const pendingDelivery = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate }, hostWorker,
    async (bearer) => assertRequest(kernel.http, bearer, ids.aggregate, 'read', 403));
  await assertRequest(kernel.http, pendingDelivery.bearer, ids.aggregate, 'read', 200);

  await assertRequest(kernel.http, '', ids.aggregate, 'read', 403);
  await assertRequest(kernel.http, validBearer, ids.aggregate, 'execute', 403);
  await assertRequest(kernel.http, validBearer, ids.otherAggregate, 'read', 403);

  const otherPrincipal = await issue({ principalId: ids.otherPrincipal, environmentId: ids.environment, audience, aggregateId: ids.aggregate });
  const otherEnvironment = await issue({ principalId: ids.principal, environmentId: ids.otherEnvironment, audience, aggregateId: ids.aggregate });
  const otherAudience = await issue({ principalId: ids.principal, environmentId: ids.environment, audience: 'pocketwiki.context', aggregateId: ids.aggregate });
  const expired = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate, nowMS: Date.now() - LOCAL_CREDENTIAL_TTL_MS - 1000 });
  for (const token of [otherPrincipal.bearer, otherEnvironment.bearer, otherAudience.bearer, expired.bearer]) await assertRequest(kernel.http, token, ids.aggregate, 'read', 403);

  await hostWorker.call({ method: 'revoke', hostId: valid.hostId, bearer: validBearer });
  await assertRequest(kernel.http, validBearer, ids.aggregate, 'read', 403);

  const failedDelivery = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate, failDelivery: true });
  assert.equal(failedDelivery.error, 'ERR_DELIVERY');
  await assertRequest(kernel.http, failedDelivery.bearer, ids.aggregate, 'read', 403);

  const disconnected = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate, failDelivery: true, disconnectBeforeDeliveryFailure: true });
  await assertRequest(kernel.http, disconnected.bearer, ids.aggregate, 'read', 403);
  assert.equal(disconnected.error, 'ERR_DELIVERY');
  await rename(`${socketPath}.offline`, socketPath);

  // Relay the activation to the real Kernel, then drop its response. This
  // closes the owner after the activation ACK is lost.
  const proxyPath = path.join(temp, 'drop-ack.sock');
  proxy = net.createServer((client) => {
    const upstream = net.connect(socketPath);
    for (const socket of [client, upstream]) {
      proxySockets.add(socket);
      socket.once('close', () => proxySockets.delete(socket));
    }
    client.pipe(upstream);
    upstream.once('data', () => { client.destroy(); upstream.destroy(); });
    upstream.on('error', () => client.destroy());
    client.on('error', () => upstream.destroy());
  });
  await withTimeout(new Promise((resolve, reject) => { proxy.once('error', reject); proxy.listen(proxyPath, resolve); }), 'proxy startup');
  const unknown = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate, socketPath: proxyPath }, hostWorker,
    (bearer) => armClosure(kernel.http, bearer));
  assert.equal(unknown.error, 'ERR_ACTIVATION_UNKNOWN');
  await awaitClosure(kernel.http, unknown.bearer);
  await assertRequest(kernel.http, unknown.bearer, ids.aggregate, 'read', 403);
  await new Promise((resolve) => proxy.close(resolve));
  proxy = undefined;

  const restart = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate });
  const restartBearer = restart.bearer;
  await assert.equal(await effectCount(kernel.http), 2, 'all denials occur before the test effect');

  const disk = await readFile(storePath, 'utf8');
  const logs = `${hostWorker.logs.join('')}\n${kernelLogBuffers.flat().join('')}`;
  for (const token of [validBearer, pendingDelivery.bearer, otherPrincipal.bearer, otherEnvironment.bearer, otherAudience.bearer, expired.bearer, failedDelivery.bearer, disconnected.bearer, unknown.bearer, restartBearer]) {
    assert.ok(!disk.includes(token), 'bearer must not persist');
    assert.ok(!logs.includes(token), 'bearer must not appear in process logs');
  }
  assert.ok(disk.includes('token_sha256'));

  secondHost = await startHostWorker();
  const second = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate }, secondHost);
  await assertRequest(kernel.http, second.bearer, ids.aggregate, 'read', 200);
  // The Kernel and second host stay alive; kill only the first host.
  await armClosure(kernel.http, restartBearer);
  const exited = once(hostWorker.child, 'exit');
  hostWorker.child.kill('SIGKILL');
  await withTimeout(exited, 'host termination');
  await awaitClosure(kernel.http, restartBearer);
  await assertRequest(kernel.http, restartBearer, ids.aggregate, 'read', 403);
  await assertRequest(kernel.http, second.bearer, ids.aggregate, 'read', 200);
  const restartedHost = await startHostWorker();
  const fresh = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate }, restartedHost);
  await assertRequest(kernel.http, restartBearer, ids.aggregate, 'read', 403);
  await assertRequest(kernel.http, fresh.bearer, ids.aggregate, 'read', 200);
  assert.equal(await effectCount(kernel.http), 5, 'denials have no effect and other hosts remain active');
  const laterDisk = await readFile(storePath, 'utf8');
  const laterLogs = `${secondHost.logs.join('')}\n${restartedHost.logs.join('')}\n${kernelLogBuffers.flat().join('')}`;
  for (const token of [second.bearer, fresh.bearer]) {
    assert.ok(!laterDisk.includes(token), 'bearer must not persist');
    assert.ok(!laterLogs.includes(token), 'bearer must not appear in process logs');
  }

  await stopKernel(kernel);
  kernel = await startKernel();
  await assertRequest(kernel.http, restartBearer, ids.aggregate, 'read', 403);
  assert.equal(await effectCount(kernel.http), 0, 'Kernel restart invalidates prior local credentials');
  console.log('AC-05 process integration passed: scoped allow, principal/environment/audience/scope/aggregate/expiry/revoke/delivery/restart denials before effect; store contains hashes only');
} finally {
  for (const socket of proxySockets) socket.destroy();
  if (proxy?.listening) await new Promise((resolve) => proxy.close(resolve));
  if (hostWorker) await terminate(hostWorker.child);
  if (secondHost) await terminate(secondHost.child);
  for (const child of children) await stopKernel({ child });
  await rm(temp, { recursive: true, force: true });
}

async function issue(config, worker = hostWorker, onBearer) {
  const hostId = `host-${Math.random()}`;
  const result = await worker.call({
    method: 'issue', id: hostId,
    config: {
      socketPath: config.socketPath ?? socketPath, principalId: config.principalId, environmentId: config.environmentId,
      audience: config.audience, aggregateId: config.aggregateId,
      grantedScopes: config.grantedScopes ?? ['read'], requestedScopes: config.requestedScopes ?? ['read'],
      nowMS: config.nowMS, failDelivery: Boolean(config.failDelivery), disconnectBeforeDeliveryFailure: Boolean(config.disconnectBeforeDeliveryFailure),
      ...(config.grantScopes ? { grant: { principal_id: config.principalId, environment_id: config.environmentId, audience: config.audience, aggregate_id: config.aggregateId, scopes: config.grantScopes } } : {})
    }
  }, onBearer);
  return { ...result, hostId };
}

async function armClosure(base, bearer) {
  const response = await fetch(`${base}/test/watch`, { method: 'POST', headers: { authorization: `Bearer ${bearer}` }, signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 204);
}

async function awaitClosure(base, bearer) {
  const response = await fetch(`${base}/test/closed`, { method: 'POST', headers: { authorization: `Bearer ${bearer}` }, signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 204);
}

async function startHostWorker() {
  const worker = fork(fileURLToPath(new URL('./nh00-local-host-worker.mjs', import.meta.url)), [], { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  children.push(worker);
  const logs = [];
  worker.stdout.on('data', (chunk) => logs.push(chunk.toString()));
  worker.stderr.on('data', (chunk) => logs.push(chunk.toString()));
  const pending = new Map();
  worker.on('message', (message) => {
    if (message.type === 'ready') return;
    const entry = pending.get(message.id);
    if (!entry) return;
    if (message.type === 'bearer') {
      entry.bearer = message.bearer;
      Promise.resolve().then(() => entry.onBearer?.(message.bearer)).then(() => {
        if (pending.has(message.id)) worker.send({ id: message.id, method: 'deliveryAck' });
      }, (error) => { pending.delete(message.id); entry.reject(error); });
    }
    if (message.type === 'complete') {
      pending.delete(message.id);
      entry.resolve({ ...message, bearer: entry.bearer });
    }
  });
  await withTimeout(new Promise((resolve, reject) => {
    worker.once('message', (message) => message.type === 'ready' ? resolve() : reject(new Error('Host worker did not become ready')));
    worker.once('error', reject);
  }), 'host worker startup');
  return {
    child: worker,
    logs,
    call(message, onBearer) {
      const id = message.id ?? `command-${Math.random()}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('Host worker request timed out')); }, 5000);
        pending.set(id, { resolve: (value) => { clearTimeout(timer); resolve(value); }, reject: (error) => { clearTimeout(timer); reject(error); }, bearer: undefined, onBearer });
        worker.send({ ...message, id });
      });
    }
  };
}

async function startKernel() {
  const child = spawn(binary, ['-listen', '127.0.0.1:0', '-bootstrap-socket', socketPath, '-store', storePath], { stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  const logs = [];
  kernelLogBuffers.push(logs);
  const lines = createInterface({ input: child.stdout });
  lines.on('line', (line) => logs.push(`${line}\n`));
  child.stderr.on('data', (chunk) => logs.push(chunk.toString()));
  const ready = await withTimeout(new Promise((resolve, reject) => {
    const onExit = (code) => reject(new Error(`Kernel probe exited before ready (${code})`));
    child.once('exit', onExit);
    lines.on('line', (line) => {
      if (!line.startsWith('READY ')) return;
      child.off('exit', onExit);
      resolve(JSON.parse(line.slice(6)));
    });
    child.once('error', reject);
  }), 'Kernel startup');
  return { child, lines, logs, http: ready.http };
}

async function stopKernel(kernel) {
  if (!kernel?.child || kernel.child.exitCode !== null) return;
  await terminate(kernel.child);
  kernel.lines?.close();
}

async function assertRequest(base, bearer, aggregate, scope, status) {
  const url = `${base}/test/probe/${aggregate}/${scope}`;
  if (bearer) assert.ok(!url.includes(bearer), 'bearer must not be placed in a URL');
  const response = await fetch(url, {
    method: 'POST',
    headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
    signal: AbortSignal.timeout(5000),
    body: ''
  });
  assert.equal(response.status, status, `probe ${scope} expected HTTP ${status}`);
  await response.arrayBuffer();
}

async function effectCount(base) {
  const response = await fetch(`${base}/test/effects`, { signal: AbortSignal.timeout(5000) });
  assert.equal(response.status, 200);
  return (await response.json()).effect_count;
}

async function terminate(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit').then(() => true);
  child.kill('SIGTERM');
  if (await Promise.race([exited, delay(1000).then(() => false)])) return;
  child.kill('SIGKILL');
  await Promise.race([exited, delay(1000)]);
}

function delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }

async function withTimeout(promise, operation) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${operation} timed out`)), 5000); })]);
  } finally {
    clearTimeout(timer);
  }
}
