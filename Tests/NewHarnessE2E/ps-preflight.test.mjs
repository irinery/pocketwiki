import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, access, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireProcessListing, runWithinDeadline } from './deadline-sync.mjs';
import { runAndCapture } from './deadline-process.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

test('ps preflight accepts the real process table', () => {
  assert.doesNotThrow(() => requireProcessListing());
});

test('missing ps fails the runner and both process launchers before any workload', async (t) => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), 'nh-ps-preflight-'));
  t.after(() => rm(tmp, { recursive: true, force: true }));
  const marker = path.join(tmp, 'workload-started');
  const report = path.join(tmp, 'report');
  const env = { ...process.env, PATH: tmp, NH_TEST_MARKER: marker };
  await writeFile(path.join(tmp, 'git'), '#!/bin/sh\n: > "$NH_TEST_MARKER"\n', { mode: 0o755 });
  const runner = spawnSync(process.execPath, [path.join(root, 'Tests/NewHarnessE2E/runner.mjs'), '--stage', 'E0', '--surface', 'service', '--report-dir', report], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(runner.status, 2);
  assert.match(runner.stderr, /ps indisponível/);
  await assert.rejects(access(marker), { code: 'ENOENT' });
  await assert.rejects(access(report), { code: 'ENOENT' });
  const program = `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'started')`;
  const deadline = await runWithinDeadline(process.execPath, ['-e', program], { env }, Date.now() + 5000);
  assert.equal(deadline.status, null);
  assert.equal(deadline.error.exitCode, 2);
  const captured = await runAndCapture(process.execPath, ['-e', program], root, env, 5000);
  assert.equal(captured.status, 2);
  assert.match(captured.output, /ps indisponível/);
  await assert.rejects(access(marker), { code: 'ENOENT' });
});

test('ps reporting success without a usable process table is rejected', async (t) => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), 'nh-ps-invalid-'));
  t.after(() => rm(tmp, { recursive: true, force: true }));
  await writeFile(path.join(tmp, 'ps'), '#!/bin/sh\nprintf "not a process table\\n"\n', { mode: 0o755 });
  assert.throws(() => requireProcessListing({ ...process.env, PATH: tmp }), /ps indisponível/);
});
