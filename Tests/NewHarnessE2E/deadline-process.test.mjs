import test from 'node:test';
import assert from 'node:assert/strict';
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
  const timeout = runWithinDeadline(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, Date.now() + 100);
  assert.equal(timeout.status, null);
  assert.equal(timeout.error.code, 'ETIMEDOUT');
  const expired = runWithinDeadline(process.execPath, ['-e', 'process.exit(0)'], {}, Date.now() - 1);
  assert.equal(expired.status, null);
  assert.match(expired.error.message, /deadline exceeded/);
});
