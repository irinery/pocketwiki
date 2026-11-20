import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fork } from 'node:child_process';
import { mkdtemp, rm, writeFile, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const worker = new URL('./recovery-contract-worker.mjs', import.meta.url);
const uuid = (suffix) => `10000000-0000-4000-8000-${suffix.padStart(12, '0')}`;
const payload = Buffer.from('fixture-content-never-log-this');
const envelope = {
  journal_version:1,
  command_id:uuid('1'), receipt_id:uuid('2'), principal_id:uuid('3'),
  environment_id:uuid('4'), project_id:uuid('5'), thread_id:uuid('6'),
  operation:'memory.capture_scoped', scopes:['memory.write'],
  command_sha256:'a'.repeat(64), payload_sha256:createHash('sha256').update(payload).digest('hex'),
  payload_base64:payload.toString('base64')
};

async function inspectInProcess(value, { symlinkJournal = false } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'memory-recovery-contract-'));
  try {
    const file = path.join(directory, '.capture-intent.json');
    if (symlinkJournal) {
      const target = path.join(directory, 'other.json');
      await writeFile(target, JSON.stringify(value), { mode:0o600 });
      await symlink(target, file);
    } else {
      await writeFile(file, JSON.stringify(value), { mode:0o600 });
    }
    return await new Promise((resolve, reject) => {
      const child = fork(worker, [], { stdio:['ignore', 'pipe', 'pipe', 'ipc'] });
      let stdout = '', stderr = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      let result;
      child.on('message', (message) => { result = message; });
      child.on('error', reject);
      child.on('exit', (code) => {
        if (code !== 0) return reject(new Error(`worker exited ${code}: ${stderr}`));
        resolve({ result, stdout, stderr });
      });
      child.send({ directory, name:'.capture-intent.json' });
    });
  } finally { await rm(directory, { recursive:true, force:true }); }
}

test('envelope proposto sem autoridade real permanece bloqueado e não expõe conteúdo', async () => {
  const result = await inspectInProcess(envelope);
  assert.deepEqual(result.result, { status:'blocked', code:'ERR_UNAVAILABLE' });
  assert.equal(result.stdout.includes('fixture-content-never-log-this'), false);
  assert.equal(result.stderr.includes('fixture-content-never-log-this'), false);
});

test('journal legado, identidade ausente ou adulteração nunca viram autorização', async () => {
  for (const value of [
    { events:[], ledger:{} },
    { ...envelope, principal_id:undefined },
    { ...envelope, payload_sha256:'b'.repeat(64) },
    { ...envelope, scopes:['memory.write', 'execute'] },
    { ...envelope, forged_authorized:true }
  ]) {
    const { result } = await inspectInProcess(value);
    assert.equal(result.status, 'blocked');
    assert.notEqual(result.code, 'OK');
  }
});

test('replay após suposta revogação não depende de boolean nem libera execução', async () => {
  const first = await inspectInProcess(envelope);
  const second = await inspectInProcess({ ...envelope, revoked:true });
  assert.equal(first.result.status, 'blocked');
  assert.equal(second.result.status, 'blocked');
});

test('journal em symlink é negado sem recuperar conteúdo', async () => {
  const { result } = await inspectInProcess(envelope, { symlinkJournal:true });
  assert.deepEqual(result, { status:'blocked', code:'ERR_FORBIDDEN' });
});
