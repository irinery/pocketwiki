import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { sanitizeWebTrace } from './web-trace.mjs';

test('trace is redacted in all archive members before publication', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'trace-test-'));
  try {
    const input = path.join(root, 'input'); await mkdir(input);
    await writeFile(path.join(input, 'trace.trace'), 'Authorization: Bearer secret-fixture\nsecret-fixture');
    await writeFile(path.join(input, 'resource'), Buffer.from('binary\0secret-fixture\0end'));
    const raw = path.join(root, 'raw.zip'), output = path.join(root, 'safe.zip');
    execFileSync('zip', ['-qr', raw, '.'], { cwd: input });
    await sanitizeWebTrace(raw, root, output, ['secret-fixture']);
    for (const file of ['trace.trace', 'resource']) {
      const bytes = execFileSync('unzip', ['-p', output, file]);
      assert.equal(bytes.includes(Buffer.from('secret-fixture')), false);
      assert.equal(bytes.includes(Buffer.from('[REDACTED]')), true);
    }
    await assert.rejects(sanitizeWebTrace(raw, root, path.join(root, 'unsafe.zip'), []));
    await assert.rejects(readFile(path.join(root, 'unsafe.zip')), { code: 'ENOENT' });
  } finally { await rm(root, { recursive: true, force: true }); }
});
