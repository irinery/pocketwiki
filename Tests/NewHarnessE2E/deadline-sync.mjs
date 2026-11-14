import { spawnSync } from 'node:child_process';

export function runWithinDeadline(binary, args, options, deadline, cap = 180_000) {
  const timeLeft = Math.min(cap, deadline - Date.now());
  if (timeLeft <= 0) return { status: null, error: new Error('global scenario deadline exceeded') };
  return spawnSync(binary, args, { ...options, timeout: timeLeft });
}
