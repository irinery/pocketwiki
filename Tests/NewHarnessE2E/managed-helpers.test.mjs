import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHelperLauncher, cleanupManagedHelpers } from './MacOSHost/managed-helpers.mjs';

test('owned helper cleanup covers success, failure and timeout teardown', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-helper-cleanup-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  for (const phase of ['success', 'failure', 'timeout']) {
    const binary = path.join(dir, 'helper-' + phase), launcher = path.join(dir, 'launcher-' + phase), ledger = path.join(dir, 'pids-' + phase);
    await copyFile('/bin/sleep', binary);
    await createHelperLauncher(launcher, binary, ledger);
    const ready = new Promise((resolve, reject) => {
      const watcher = watch(dir, (_, name) => { if (name === path.basename(ledger)) { watcher.close(); resolve(); } });
      watcher.on('error', reject);
    });
    const child = spawn(launcher, ['60'], { stdio: 'ignore' });
    const exited = new Promise(resolve => child.once('exit', resolve));
    await ready;
    const deadline = Date.now() + 2000;
    while (!(await readFile(ledger, 'utf8')).trim() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
    assert.match((await readFile(ledger, 'utf8')).trim(), new RegExp('^' + child.pid + '\\|'));
    try { if (phase !== 'success') throw new Error(phase); } catch (error) { assert.equal(error.message, phase); }
    finally { await cleanupManagedHelpers([{ ledger, binary, launcher }]); }
    await exited;
    assert.notEqual(child.signalCode, null);
    await cleanupManagedHelpers([{ ledger, binary, launcher }]);
  }
});

test('cleanup refuses PID reuse or unrelated executable', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-helper-identity-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const ledger = path.join(dir, 'pids'); const { spawnSync } = await import('node:child_process');
  const started = spawnSync('ps', ['-p', String(process.pid), '-o', 'lstart='], { env: { ...process.env, LC_ALL: 'C' }, encoding: 'utf8' }).stdout.trim();
  await writeFile(ledger, String(process.pid) + '|' + started + '\n');
  await assert.rejects(cleanupManagedHelpers([{ ledger, binary: path.join(dir, 'other') }]), /identity changed/);
});


test('cleanup fails closed if PID ledger disappears', async () => {
  await assert.rejects(cleanupManagedHelpers([{ ledger: '/nonexistent/nh-ledger', binary: '/nonexistent/nh-helper' }]), /ledger unavailable/);
});

test('timeout of a detached scenario still cleans its recorded helper', async t => {
  const { runWithinDeadline } = await import('./deadline-sync.mjs');
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-helper-timeout-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binary = path.join(dir, 'helper'), launcher = path.join(dir, 'launcher'), ledger = path.join(dir, 'pids');
  await copyFile('/bin/sleep', binary);
  await createHelperLauncher(launcher, binary, ledger);
  const script = "const {spawn}=require('node:child_process'); const c=spawn(process.argv[1],['60'],{detached:true,stdio:'ignore'}); c.unref(); setTimeout(()=>{},60000);";
  const result = await runWithinDeadline(process.execPath, ['-e', script, launcher], { env: process.env, encoding: 'utf8' }, Date.now() + 800, 800);
  assert.equal(result.status, null);
  assert.equal(result.error?.code, 'ETIMEDOUT');
  const pid = Number((await readFile(ledger, 'utf8')).trim().split('|')[0]);
  assert.ok(pid > 0);
  await cleanupManagedHelpers([{ ledger, binary, launcher }]);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});


test('cleanup continues after bad records and terminates the next owned helper', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-helper-continue-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binary = path.join(dir, 'helper'), launcher = path.join(dir, 'launcher'), ledger = path.join(dir, 'pids');
  await copyFile('/bin/sleep', binary); await createHelperLauncher(launcher, binary, ledger);
  const child = spawn(launcher, ['60'], { stdio: 'ignore' });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const deadline = Date.now() + 3000;
  while (!(await readFile(ledger, 'utf8')).trim() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
  const good = await readFile(ledger, 'utf8'); assert.ok(good);
  await writeFile(ledger, 'invalid\n' + good);
  await assert.rejects(cleanupManagedHelpers([{ ledger, binary, launcher }]), /invalid helper PID/);
  await exited; assert.notEqual(child.signalCode, null);
});

test('cleanup rejects a PID whose recorded start time differs', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-helper-start-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const ledger = path.join(dir, 'pids');
  await writeFile(ledger, String(process.pid) + '|Mon Jan  1 00:00:00 1900\n');
  await assert.rejects(cleanupManagedHelpers([{ ledger, binary: process.execPath }]), /start time changed/);
});
