import { killProcessTree } from './deadline-sync.mjs';
import { spawn } from 'node:child_process';

// A timeout is always a failure, even if the process subsequently reports exit 0.
export function runAndCapture(command, args, cwd, env, timeout) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { killProcessTree(child.pid); } catch (error) { output += '\nFAIL: cleanup failed: ' + error.message + '\n'; }
    }, timeout);
    child.stdout.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
    child.once('error', (error) => { clearTimeout(timer); resolve({ status: 2, output: 'Falha ao iniciar processo: ' + error.message + '\n' }); });
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ status: timedOut ? 1 : (code ?? 2), output: output + (timedOut ? '\nFAIL: deadline exceeded\n' : '') + (signal ? '\nprocess signal: ' + signal + '\n' : '') });
    });
  });
}
