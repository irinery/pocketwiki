import { renameSync } from 'node:fs';
import path from 'node:path';
const [root, outside] = process.argv.slice(2);
const slot = path.join(root, 'slot');
const held = path.join(outside, 'held');
const saved = path.join(outside, 'saved');
const secret = path.join(outside, 'secret.txt');
process.stdout.write('started\n');
for (let i = 0; i < 1000; i++) {
  try {
    renameSync(slot, held);
    renameSync(path.join(held, 'page.txt'), saved);
    renameSync(secret, path.join(held, 'page.txt'));
    renameSync(path.join(held, 'page.txt'), secret);
    renameSync(saved, path.join(held, 'page.txt'));
    renameSync(held, slot);
  } catch (error) { process.stderr.write(`${error.code}\n`); process.exit(1); }
}
