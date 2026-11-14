import { spawn } from 'node:child_process';

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
      try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); }
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
