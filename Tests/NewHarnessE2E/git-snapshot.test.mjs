import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { exportGitSnapshot } from './git-snapshot.mjs';

test('export uses pinned tree and excludes ignored source injection', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'nh-snapshot-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const repo = path.join(root, 'source'); await mkdir(repo);
  execFileSync('git', ['init', '-q', repo]);
  await writeFile(path.join(repo, '.gitignore'), 'injected.go\n');
  await writeFile(path.join(repo, 'main.go'), 'package main\n');
  execFileSync('git', ['-C', repo, 'add', '.']);
  execFileSync('git', ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture']);
  const sha = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  await writeFile(path.join(repo, 'injected.go'), 'package main\n');
  const dest = await exportGitSnapshot(repo, sha, path.join(root, 'export'));
  assert.equal(await readFile(path.join(dest, 'main.go'), 'utf8'), 'package main\n');
  await assert.rejects(readFile(path.join(dest, 'injected.go')), { code: 'ENOENT' });
  await assert.rejects(exportGitSnapshot(repo, 'f'.repeat(40), path.join(root, 'wrong')), /differs/);
});
