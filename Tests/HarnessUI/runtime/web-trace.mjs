import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const run = promisify(execFile);

// The raw trace stays under the private temporary root. Only the rebuilt archive
// is written to the report, after every archive member has been checked.
export async function sanitizeWebTrace(raw, root, destination, secrets) {
  if (!secrets.length || secrets.some(secret => typeof secret !== 'string' || !secret)) throw new Error('trace secrets unavailable');
  const unpacked = path.join(root, 'web-trace-unpacked');
  await mkdir(unpacked);
  await run('unzip', ['-q', raw, '-d', unpacked]);
  async function clean(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) { await clean(file); continue; }
      if (!entry.isFile()) throw new Error('unexpected trace member');
      let bytes = await readFile(file);
      for (const secret of secrets) {
        const needle = Buffer.from(secret);
        while (bytes.includes(needle)) {
          const offset = bytes.indexOf(needle);
          bytes = Buffer.concat([bytes.subarray(0, offset), Buffer.from('[REDACTED]'), bytes.subarray(offset + needle.length)]);
        }
      }
      await writeFile(file, bytes, { mode: 0o600 });
    }
  }
  await clean(unpacked);
  const sanitized = path.join(root, 'web-trace-redacted.zip');
  await run('zip', ['-qr', sanitized, '.'], { cwd: unpacked });
  await writeFile(destination, await readFile(sanitized), { mode: 0o600 });
}
