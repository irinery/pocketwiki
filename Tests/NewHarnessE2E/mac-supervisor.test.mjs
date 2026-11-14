import { spawnSync as inspectProcess } from 'node:child_process';
import test from 'node:test';
import assert from 'node:assert/strict';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { helperPaths, superviseMacHost } from './MacOSHost/supervisor.mjs';
import { cleanupManagedHelpers } from './MacOSHost/managed-helpers.mjs';

test('supervisor cleans reparented helper after host timeout SIGKILL', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-supervisor-test-'));
  const pidFile = path.join(dir, 'pid'), helperDirFile = path.join(dir, 'helper-dir');
  t.after(async () => {
    try {
      const helperDir = await readFile(helperDirFile, 'utf8');
      let exists = true;
      try { await access(helperDir); } catch (error) { if (error.code === 'ENOENT') exists = false; else throw error; }
      if (exists) {
        await cleanupManagedHelpers(helperPaths(helperDir));
        await rm(helperDir, { recursive: true, force: true });
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    await rm(dir, { recursive: true, force: true });
  });
  const intermediate = "const {spawn}=require('node:child_process');const fs=require('node:fs');const c=spawn(process.argv[1],['60'],{detached:true,stdio:'ignore'});fs.writeFileSync(process.argv[2],String(c.pid));c.unref();";
  const host = "const {spawnSync}=require('node:child_process');const fs=require('node:fs');const p=require('node:path');const d=process.env.NH_MAC_HELPER_DIR;fs.writeFileSync(process.argv[3],d);fs.copyFileSync('/bin/sleep',p.join(d,'kernel.real'));spawnSync(process.execPath,['-e',process.argv[1],p.join(d,'kernel'),process.argv[2]]);setTimeout(()=>{},60000);";
  const result = await superviseMacHost(process.execPath, ['-e', host, intermediate, pidFile, helperDirFile], { env: process.env, encoding: 'utf8' }, Date.now() + 1200, 1200);
  assert.equal(result.status, null);
  assert.equal(result.error?.code, 'ETIMEDOUT');
  const pid = Number(await readFile(pidFile, 'utf8')); assert.ok(pid > 0);
  const status = inspectProcess('ps', ['-p', String(pid), '-o', 'stat='], { encoding: 'utf8' });
  assert.ok(status.status === 1 || (status.status === 0 && status.stdout.trim().startsWith('Z')), 'helper must be gone or a non-running zombie');
});


test('supervisor retains timeout cause when cleanup also fails', async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-supervisor-failure-'));
  const helperDirFile = path.join(dir, 'helper-dir');
  t.after(async () => {
    try { await rm(await readFile(helperDirFile, 'utf8'), { recursive: true, force: true }); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await rm(dir, { recursive: true, force: true });
  });
  const host = "const fs=require('node:fs'),p=require('node:path'),d=process.env.NH_MAC_HELPER_DIR;fs.writeFileSync(process.argv[1],d);fs.unlinkSync(p.join(d,'kernel.pids'));setTimeout(()=>{},60000);";
  const result = await superviseMacHost(process.execPath, ['-e', host, helperDirFile], { env: process.env, encoding: 'utf8' }, Date.now() + 800, 800);
  assert.equal(result.status, null);
  assert.equal(result.error?.code, 'ETIMEDOUT');
  assert.match(result.error.message, /cleanup failed.*ledger unavailable/);
  assert.equal(result.error.cause?.code, 'ETIMEDOUT');
});
