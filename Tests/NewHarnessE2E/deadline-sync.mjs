import { spawn, spawnSync } from 'node:child_process';

// Run each command in its own process group so timeout kills the complete tree.
export function runWithinDeadline(binary, args, options, deadline, cap = 180_000) {
  const timeLeft = Math.min(cap, deadline - Date.now());
  if (timeLeft <= 0) return Promise.resolve({ status: null, error: new Error('global scenario deadline exceeded') });
  return new Promise((resolve) => {
    const child = spawn(binary, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let error;
    let exceeded = false;
    const limit = options.maxBuffer || 10 * 1024 * 1024;
    function kill() {
      try { killProcessTree(child.pid); } catch (cleanupError) {
        error = new Error('deadline exceeded; cleanup failed: ' + cleanupError.message);
        error.code = 'ETIMEDOUT';
      }
    }
    const timer = setTimeout(() => {
      exceeded = true;
      error = Object.assign(new Error('global scenario deadline exceeded'), { code: 'ETIMEDOUT' });
      kill();
    }, timeLeft);
    for (const [stream, name] of [[child.stdout, 'stdout'], [child.stderr, 'stderr']]) {
      stream.setEncoding('utf8').on('data', (chunk) => {
        if (name === 'stdout') stdout += chunk; else stderr += chunk;
        if (Buffer.byteLength(stdout) + Buffer.byteLength(stderr) > limit && !error) {
          error = new Error('process output exceeds maxBuffer');
          kill();
        }
      });
    }
    child.once('error', (err) => { error = err; });
    child.once('close', (status) => {
      clearTimeout(timer);
      resolve({ status: exceeded || error ? null : status, stdout, stderr, error });
    });
  });
}

// Stop each group before enumerating its descendants, then rescan until stable.
export function killProcessTree(rootPID, snapshotProcesses = () => spawnSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8', timeout: 5000 })) {
  const frozen = new Set();
  const stop = (pid) => {
    try { process.kill(-pid, 'SIGSTOP'); } catch {}
    try { process.kill(pid, 'SIGSTOP'); } catch {}
    frozen.add(pid);
  };
  stop(rootPID);
  let snapshotFailure;
  for (;;) {
    const snapshot = snapshotProcesses();
    if (snapshot.status !== 0 || !snapshot.stdout?.trim()) {
      snapshotFailure = new Error('process listing failed during cleanup');
      break;
    }
    const children = new Map();
    for (const line of (snapshot.stdout || '').split('\n')) {
      const match = /^\s*(\d+)\s+(\d+)\s*$/.exec(line);
      if (!match) continue;
      const pid = Number(match[1]); const parent = Number(match[2]);
      if (!children.has(parent)) children.set(parent, []);
      children.get(parent).push(pid);
    }
    let added = false;
    const pending = [rootPID];
    while (pending.length) {
      for (const pid of children.get(pending.pop()) || []) {
        pending.push(pid);
        if (!frozen.has(pid)) { stop(pid); added = true; }
      }
    }
    if (!added) break;
  }
  for (const pid of [...frozen].reverse()) {
    try { process.kill(-pid, 'SIGKILL'); } catch {}
    try { process.kill(pid, 'SIGKILL'); } catch {}
  }
  if (snapshotFailure) throw snapshotFailure;
}
