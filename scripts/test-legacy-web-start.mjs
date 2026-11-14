import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

for (const command of ['start', 'start:lan80']) {
  test(`${command} generates the marked asset before starting the server`, async () => {
    const fixture = await mkdtemp(path.join(tmpdir(), 'pocketwiki-web-start-'));
    try {
      await mkdir(path.join(fixture, 'scripts'));
      await mkdir(path.join(fixture, 'node_modules'));
      await copyFile(path.join(root, 'package.json'), path.join(fixture, 'package.json'));
      await copyFile(path.join(root, 'scripts/build-legacy-web-assets.mjs'), path.join(fixture, 'scripts/build-legacy-web-assets.mjs'));
      await symlink(path.join(root, 'node_modules/marked'), path.join(fixture, 'node_modules/marked'), 'dir');
      await writeFile(path.join(fixture, 'server.mjs'), "import { access } from 'node:fs/promises'; await access('assets/marked.min.js');\n");
      const result = spawnSync('npm', ['run', command], { cwd: fixture, encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr || result.stdout);
      assert.deepEqual(await readFile(path.join(fixture, 'assets/marked.min.js')), await readFile(path.join(root, 'node_modules/marked/lib/marked.umd.js')));
    } finally {
      await rm(fixture, { recursive: true, force: true });
    }
  });
}
