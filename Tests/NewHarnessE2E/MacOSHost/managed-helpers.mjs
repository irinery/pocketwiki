import { spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { readFileSync, readlinkSync, realpathSync } from 'node:fs';

const quote = text => "'" + text.replaceAll("'", "'\\''") + "'";
export async function createHelperLauncher(launcher, binary, ledger) {
  await writeFile(ledger, '', { mode: 0o600, flag: 'wx' });
  await writeFile(launcher, '#!/bin/sh\nstarted=$(LC_ALL=C ps -p "$$" -o lstart=) || exit 1\n[ -n "$started" ] || exit 1\nprintf "%s|%s\\n" "$$" "$started" >> ' + quote(ledger) + ' || exit 1\nexec ' + quote(binary) + ' "$@"\n', { mode: 0o700 });
}

function executable(pid, launcher, started) {
  const start = spawnSync('ps', ['-p', String(pid), '-o', 'lstart='], { env: { ...process.env, LC_ALL: 'C' }, encoding: 'utf8', timeout: 5000 });
  if (start.status === 1 && !start.stdout.trim()) return null;
  if (start.status !== 0) throw new Error('cannot verify helper start time: ' + pid);
  if (start.stdout.trim() !== started) throw new Error('helper PID start time changed: ' + pid);
  const result = spawnSync('ps', ['-p', String(pid), '-o', 'stat=,comm='], { encoding: 'utf8', timeout: 5000 });
  if (result.status === 1 && !result.stdout.trim()) return null;
  if (result.status !== 0) throw new Error('cannot verify helper process ' + pid);
  const match = /^\s*(\S+)\s+(.+?)\s*$/.exec(result.stdout);
  if (!match) throw new Error('invalid process listing for helper ' + pid);
  if (match[1].startsWith('Z')) return null;
  // Linux ps `comm` exposes a truncated task name, not an executable path.
  if (process.platform === 'linux') {
    let actual;
    try { actual = readlinkSync(`/proc/${pid}/exe`); }
    catch (error) {
      if (error.code === 'ENOENT' && spawnSync('ps', ['-p', String(pid)], { stdio: 'ignore' }).status === 1) return null;
      throw new Error('cannot inspect helper executable: ' + pid);
    }
    if (launcher) {
      const argv = readFileSync(`/proc/${pid}/cmdline`).toString().split('\0');
      if (argv[0] === '/bin/sh' && argv[1] === launcher && actual === realpathSync('/bin/sh')) return launcher;
    }
    return actual;
  }
  if (match[2] === '/bin/sh' && launcher) {
    const args = spawnSync('ps', ['-p', String(pid), '-o', 'args='], { encoding: 'utf8', timeout: 5000 });
    if (args.status !== 0) throw new Error('cannot verify helper launcher ' + pid);
    if (args.stdout.trim() === '/bin/sh ' + launcher || args.stdout.trim().startsWith('/bin/sh ' + launcher + ' ')) return launcher;
  }
  return match[2];
}

export async function cleanupManagedHelpers(entries) {
  const errors = [];
  for (const { ledger, binary, launcher } of entries) {
    let records;
    try { records = (await readFile(ledger, 'utf8')).split('\n').filter(Boolean); }
    catch (error) { errors.push('helper PID ledger unavailable: ' + error.message); continue; }
    for (const record of new Set(records)) {
      try {
      const match = /^([1-9][0-9]*)\|(.+)$/.exec(record);
      if (!match) throw new Error('invalid helper PID record');
      const pid = Number(match[1]), started = match[2].trim();
      let current = executable(pid, launcher, started);
      if (!current) continue;
      let expectedBinary = binary;
      if (process.platform === 'linux') {
        try { expectedBinary = realpathSync(binary); } catch { throw new Error('helper PID identity changed: ' + pid); }
      }
      if (current !== expectedBinary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
      try { process.kill(pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      const deadline = Date.now() + 2000;
      do {
        await new Promise(resolve => setTimeout(resolve, 50));
        current = executable(pid, launcher, started);
        if (!current) break;
        if (current !== expectedBinary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
      } while (Date.now() < deadline);
      if (current) {
        try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
        const killDeadline = Date.now() + 2000;
        do {
          await new Promise(resolve => setTimeout(resolve, 50));
          current = executable(pid, launcher, started);
          if (!current) break;
          if (current !== expectedBinary && current !== launcher) throw new Error('helper PID identity changed: ' + pid);
        } while (Date.now() < killDeadline);
        if (current) throw new Error('helper did not terminate: ' + pid);
      }
      } catch (error) { errors.push(error.message); }
    }
  }
  if (errors.length) throw new Error(errors.join('; '));
}
