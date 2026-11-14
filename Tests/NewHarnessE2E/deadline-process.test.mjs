import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { runAndCapture } from './deadline-process.mjs';

test('deadline terminates a running process and reports failure', async () => {
  const result = await runAndCapture(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], process.cwd(), process.env, 100);
  assert.equal(result.status, 1);
  assert.match(result.output, /deadline exceeded/);
});

test('process failure is preserved and successful execution passes', async () => {
  const failed = await runAndCapture(process.execPath, ['-e', 'process.exit(7)'], process.cwd(), process.env, 5000);
  assert.equal(failed.status, 7);
  const passed = await runAndCapture(process.execPath, ['-e', 'process.stdout.write("ok")'], process.cwd(), process.env, 5000);
  assert.equal(passed.status, 0);
  assert.equal(passed.output, 'ok');
});

test('synchronous shard deadline fails on timeout and expired deadline', async () => {
  const { runWithinDeadline } = await import('./deadline-sync.mjs');
  const timeout = await runWithinDeadline(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, Date.now() + 100);
  assert.equal(timeout.status, null);
  assert.equal(timeout.error.code, 'ETIMEDOUT');
  const expired = await runWithinDeadline(process.execPath, ['-e', 'process.exit(0)'], {}, Date.now() - 1);
  assert.equal(expired.status, null);
  assert.match(expired.error.message, /deadline exceeded/);
});

test('hard deadline kills a child that ignores SIGTERM and its descendant', async () => {
  const { runWithinDeadline } = await import('./deadline-sync.mjs');
  const source = `const { spawn } = require('node:child_process');
    process.on('SIGTERM', () => {});
    const child = spawn(process.execPath, ['-e', "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"]);
    console.log(child.pid); setInterval(() => {}, 1000);`;
  const start = Date.now();
  const result = await runWithinDeadline(process.execPath, ['-e', source], {}, Date.now() + 500);
  assert.equal(result.error.code, 'ETIMEDOUT');
  assert.ok(Date.now() - start < 5000);
  const pid = Number(result.stdout.trim());
  assert.ok(pid > 0);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});

test('deadline kills detached nested process groups', async () => {
  const { runWithinDeadline } = await import('./deadline-sync.mjs');
  const nested = `const { spawn } = require('node:child_process');
    const p = spawn(process.execPath, ['-e', "process.on('SIGTERM', () => {}); setInterval(() => {}, 1000)"], { detached: true, stdio: 'ignore' });
    console.log(p.pid); setInterval(() => {}, 1000);`;
  const result = await runWithinDeadline(process.execPath, ['-e', nested], {}, Date.now() + 500);
  assert.equal(result.error.code, 'ETIMEDOUT');
  const pid = Number(result.stdout.trim());
  assert.ok(pid > 0);
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});

test('cleanup rescans after discovering a detached child', async () => {
  const { killProcessTree } = await import('./deadline-sync.mjs');
  const nested = `const { spawn } = require('node:child_process');
    const source = "const {spawn}=require('node:child_process'); const p=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'}); console.log(p.pid); setInterval(()=>{},1000)";
    const p = spawn(process.execPath, ['-e', source], { detached: true });
    p.stdout.on('data', data => console.log(p.pid + ' ' + data.toString().trim())); setInterval(() => {}, 1000);`;
  const root = spawn(process.execPath, ['-e', nested], { detached: true });
  const [chunk] = await once(root.stdout, 'data');
  const [childPID, grandchildPID] = String(chunk).trim().split(/\s+/).map(Number);
  assert.ok(childPID > 0 && grandchildPID > 0);
  const closed = once(root, 'close');
  let scans = 0;
  killProcessTree(root.pid, () => {
    scans++;
    const snapshot = spawnSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' });
    // The first listing misses the newly forked grandchild; the next must find it.
    if (scans === 1) snapshot.stdout = snapshot.stdout.split('\n').filter((line) => Number(line.trim().split(/\s+/)[0]) !== grandchildPID).join('\n');
    return snapshot;
  });
  await closed;
  assert.ok(scans >= 2);
  for (const pid of [childPID, grandchildPID]) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
});
