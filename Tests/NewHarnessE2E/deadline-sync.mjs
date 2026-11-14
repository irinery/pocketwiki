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
      killProcessTree(child.pid);
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

// Descendants may have started their own process groups; enumerate before killing.
export function killProcessTree(rootPID) {
  const snapshot = spawnSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8', timeout: 5000 });
  const children = new Map();
  for (const line of (snapshot.stdout || '').split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s*$/.exec(line);
    if (!match) continue;
    const pid = Number(match[1]); const parent = Number(match[2]);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent).push(pid);
  }
  const order = [];
  function visit(pid) { for (const child of children.get(pid) || []) visit(child); order.push(pid); }
  visit(rootPID);
  for (const pid of order) {
    try { process.kill(-pid, 'SIGKILL'); } catch {}
    try { process.kill(pid, 'SIGKILL'); } catch {}
  }
}
