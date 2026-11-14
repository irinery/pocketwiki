import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile, access } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

test('failed preflight removes the prior shard report and artifacts', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-stale-report-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const report = path.join(dir, 'e1-service.json');
  const artifact = path.join(dir, 'e1-service');
  await mkdir(artifact); await writeFile(report, 'previous pass'); await writeFile(path.join(artifact, 'old.log'), 'old');
  const result = spawnSync(process.execPath, ['Tests/NewHarnessE2E/runner.mjs', '--stage', 'E1', '--surface', 'service', '--report-dir', dir], { env: { ...process.env, POCKETKERNEL_NH00_ROOT: path.join(dir, 'missing') }, encoding: 'utf8' });
  assert.equal(result.status, 2);
  await assert.rejects(access(report), { code: 'ENOENT' });
  await assert.rejects(access(artifact), { code: 'ENOENT' });
});
