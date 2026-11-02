import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
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

  const restart = await issue({ principalId: ids.principal, environmentId: ids.environment, audience, aggregateId: ids.aggregate });
  const restartBearer = restart.bearer;
  await assert.equal(await effectCount(kernel.http), 1, 'all denials occur before the test effect');

  const disk = await readFile(storePath, 'utf8');
  const logs = `${hostWorker.logs.join('')}\n${kernelLogBuffers.flat().join('')}`;
  for (const token of [validBearer, otherPrincipal.bearer, otherEnvironment.bearer, otherAudience.bearer, expired.bearer, failedDelivery.bearer, restartBearer]) {
    assert.ok(!disk.includes(token), 'bearer must not persist');
    assert.ok(!logs.includes(token), 'bearer must not appear in process logs');
  }
  assert.ok(disk.includes('token_sha256'));

  await stopKernel(kernel);
  kernel = await startKernel();
  await assertRequest(kernel.http, restartBearer, ids.aggregate, 'read', 403);
  assert.equal(await effectCount(kernel.http), 0, 'Kernel restart invalidates prior local credentials');
  console.log('AC-05 process integration passed: scoped allow, principal/environment/audience/scope/aggregate/expiry/revoke/delivery/restart denials before effect; store contains hashes only');
} finally {
  if (hostWorker) await terminate(hostWorker.child);
  for (const child of children) await stopKernel({ child });
  await rm(temp, { recursive: true, force: true });
}

async function issue(config) {
  const hostId = `host-${Math.random()}`;
  const result = await hostWorker.call({
    method: 'issue', id: hostId,
    config: {
      socketPath, principalId: config.principalId, environmentId: config.environmentId,
      audience: config.audience, aggregateId: config.aggregateId,
      grantedScopes: config.grantedScopes ?? ['read'], requestedScopes: config.requestedScopes ?? ['read'],
      nowMS: config.nowMS, failDelivery: Boolean(config.failDelivery),
      ...(config.grantScopes ? { grant: { principal_id: config.principalId, environment_id: config.environmentId, audience: config.audience, aggregate_id: config.aggregateId, scopes: config.grantScopes } } : {})
    }
  });
  return { ...result, hostId };
}

async function startHostWorker() {
  const worker = fork(fileURLToPath(new URL('./nh00-local-host-worker.mjs', import.meta.url)), [], { stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  const logs = [];
  worker.stdout.on('data', (chunk) => logs.push(chunk.toString()));
  worker.stderr.on('data', (chunk) => logs.push(chunk.toString()));
  const pending = new Map();
  worker.on('message', (message) => {
    if (message.type === 'ready') return;
    const entry = pending.get(message.id);
    if (!entry) return;
    if (message.type === 'bearer') entry.bearer = message.bearer;
    if (message.type === 'complete') {
      pending.delete(message.id);
      entry.resolve({ ...message, bearer: entry.bearer });
    }
  });
  await new Promise((resolve, reject) => {
    worker.once('message', (message) => message.type === 'ready' ? resolve() : reject(new Error('Host worker did not become ready')));
    worker.once('error', reject);
  });
  return {
    child: worker,
    logs,
    call(message) {
      const id = message.id ?? `command-${Math.random()}`;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject, bearer: undefined });
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
  const ready = await new Promise((resolve, reject) => {
    const onExit = (code) => reject(new Error(`Kernel probe exited before ready (${code})`));
    child.once('exit', onExit);
    lines.on('line', (line) => {
      if (!line.startsWith('READY ')) return;
      child.off('exit', onExit);
      resolve(JSON.parse(line.slice(6)));
    });
    child.once('error', reject);
  });
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
    body: ''
  });
  assert.equal(response.status, status, `probe ${scope} expected HTTP ${status}`);
  await response.arrayBuffer();
}

async function effectCount(base) {
  const response = await fetch(`${base}/test/effects`);
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
