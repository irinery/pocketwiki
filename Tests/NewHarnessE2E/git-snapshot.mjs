import { spawnSync } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

// Build only files in the immutable tree, never ignored or untracked worktree files.
export async function exportGitSnapshot(repository, sha, destination) {
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('invalid pinned SHA');
  const head = spawnSync('git', ['-C', repository, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  const status = spawnSync('git', ['-C', repository, 'status', '--porcelain=v1', '--untracked-files=no'], { encoding: 'utf8' });
  if (head.status !== 0 || head.stdout.trim() !== sha || status.status !== 0 || status.stdout.trim()) throw new Error('pinned checkout differs or has tracked modifications: ' + repository);
  await mkdir(path.dirname(destination), { recursive: true });
  const clone = spawnSync('git', ['clone', '--shared', '--no-checkout', repository, destination], { encoding: 'utf8', timeout: 30_000 });
  if (clone.status !== 0) throw new Error('cannot clone pinned snapshot: ' + (clone.stderr || clone.error?.message || 'git clone failed'));
  const checkout = spawnSync('git', ['-C', destination, 'checkout', '--detach', sha], { encoding: 'utf8', timeout: 30_000 });
  if (checkout.status !== 0) throw new Error('cannot checkout pinned snapshot: ' + (checkout.stderr || checkout.error?.message || 'git checkout failed'));
  return destination;
}
