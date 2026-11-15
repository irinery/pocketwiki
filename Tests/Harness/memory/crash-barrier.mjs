// Test-only process boundary: pause the worker after the intent rename has
// completed, before the store can start applying the journal.
import * as fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import path from 'node:path';

export function installCrashBarrier(target) {
  const originalRename = fs.default.rename;
  fs.default.rename = async (source, destination) => {
    await originalRename(source, destination);
    if (path.resolve(destination) !== path.resolve(target)) return;
    await new Promise((resolve, reject) => {
      process.send({ type:'journal-persisted' }, (cause) => cause ? reject(cause) : resolve());
    });
    await new Promise(() => {});
  };
  syncBuiltinESMExports();
}
