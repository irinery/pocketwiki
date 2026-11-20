import { renameSync, symlinkSync, unlinkSync } from 'node:fs';
import path from 'node:path';
const [root, outside] = process.argv.slice(2);
const slot = path.join(root, 'slot');
const held = path.join(root, 'held');
process.stdout.write('started\n');
for (let i = 0; i < 2000; i++) {
  try {
    renameSync(slot, held);
    symlinkSync(outside, slot);
    unlinkSync(slot);
    renameSync(held, slot);
  } catch (error) {
    process.stderr.write(`${error.code}\n`);
    process.exit(1);
  }
}
