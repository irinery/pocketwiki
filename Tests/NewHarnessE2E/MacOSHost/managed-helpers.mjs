import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';

const quote = text => "'" + text.replaceAll("'", "'\\''") + "'";
export async function createHelperLauncher(launcher, binary, ledger) {
  await writeFile(ledger, '', { mode: 0o600, flag: 'wx' });
  await writeFile(launcher, '#!/bin/sh\nprintf "%s\\n" "$$" >> ' + quote(ledger) + ' || exit 1\nexec ' + quote(binary) + ' "$@"\n', { mode: 0o700 });
}

function executable(pid, launcher) {
  const result = spawnSync('ps', ['-p', String(pid), '-o', 'stat=,comm='], { encoding: 'utf8', timeout: 5000 });
  if (result.status === 1 && !result.stdout.trim()) return null;
  if (result.status !== 0) throw new Error('cannot verify helper process ' + pid);
  const match = /^\s*(\S+)\s+(.+?)\s*$/.exec(result.stdout);
  if (!match) throw new Error('invalid process listing for helper ' + pid);
  if (match[1].startsWith('Z')) return null;
  if (match[2] === '/bin/sh' && launcher) {
    const args = spawnSync('ps', ['-p', String(pid), '-o', 'args='], { encoding: 'utf8', timeout: 5000 });
    if (args.status !== 0) throw new Error('cannot verify helper launcher ' + pid);
    if (args.stdout.trim() === '/bin/sh ' + launcher || args.stdout.trim().startsWith('/bin/sh ' + launcher + ' ')) return launcher;
  }
  return match[2];
}

export async function cleanupManagedHelpers(entries) {
  for (const { ledger, binary, launcher } of entries) {
    let records;
    try { records = (await readFile(ledger, 'utf8')).split('\n').filter(Boolean); }
    catch (error) { throw new Error('helper PID ledger unavailable: ' + error.message); }
    for (const record of new Set(records)) {
      if (!/^[1-9][0-9]*$/.test(record)) throw new Error('invalid helper PID record');
      const pid = Number(record);
      let current = executable(pid, launcher);
      if (!current) continue;
      if (current !== binary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
      try { process.kill(pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      const deadline = Date.now() + 2000;
      do {
        await new Promise(resolve => setTimeout(resolve, 50));
        current = executable(pid, launcher);
        if (!current) break;
        if (current !== binary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
      } while (Date.now() < deadline);
      if (current) {
        try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
        const killDeadline = Date.now() + 2000;
        do {
          await new Promise(resolve => setTimeout(resolve, 50));
          current = executable(pid, launcher);
          if (!current) break;
          if (current !== binary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
        } while (Date.now() < killDeadline);
        if (current) throw new Error('helper did not terminate: ' + pid);
      }
    }
  }
}
