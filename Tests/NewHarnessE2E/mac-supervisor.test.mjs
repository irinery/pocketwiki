import { spawnSync as inspectProcess } from 'node:child_process';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { superviseMacHost } from './MacOSHost/supervisor.mjs';

test('supervisor cleans reparented helper after host timeout SIGKILL', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-supervisor-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const pidFile = path.join(dir, 'pid');
  const intermediate = "const {spawn}=require('node:child_process');const fs=require('node:fs');const c=spawn(process.argv[1],['60'],{detached:true,stdio:'ignore'});fs.writeFileSync(process.argv[2],String(c.pid));c.unref();";
  const host = "const {spawnSync}=require('node:child_process');const fs=require('node:fs');const p=require('node:path');const d=process.env.NH_MAC_HELPER_DIR;fs.copyFileSync('/bin/sleep',p.join(d,'kernel.real'));spawnSync(process.execPath,['-e',process.argv[1],p.join(d,'kernel'),process.argv[2]]);setTimeout(()=>{},60000);";
  const result = await superviseMacHost(process.execPath, ['-e', host, intermediate, pidFile], { env: process.env, encoding: 'utf8' }, Date.now() + 1200, 1200);
  assert.equal(result.status, null);
  assert.equal(result.error?.code, 'ETIMEDOUT');
  const pid = Number(await readFile(pidFile, 'utf8')); assert.ok(pid > 0);
  const status = inspectProcess('ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' });
  assert.ok(status.status === 1 || (status.status === 0 && status.stdout.trim().startsWith('Z')), 'helper must be gone or a non-running zombie');
});
