import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import { runWithinDeadline } from '../deadline-sync.mjs';
import { createHelperLauncher, cleanupManagedHelpers } from './managed-helpers.mjs';

export function helperPaths(directory) {
  return ['kernel', 'middleware'].map(name => ({
    binary: path.join(directory, name + '.real'),
    launcher: path.join(directory, name),
    ledger: path.join(directory, name + '.pids')
  }));
}

// The parent owns this ledger and remains alive when the host is killed on timeout.
export async function superviseMacHost(command, args, options, deadline, cap = 30 * 60_000) {
  const directory = await mkdtemp('/tmp/nh-mac-owned-');
  const helpers = helperPaths(directory);
  let result;
  try {
    for (const item of helpers) await createHelperLauncher(item.launcher, item.binary, item.ledger);
    result = await runWithinDeadline(command, args, { ...options, env: { ...options.env, NH_MAC_HELPER_DIR: directory } }, deadline, cap);
  } finally {
    try { await cleanupManagedHelpers(helpers); }
    catch (error) {
      result ||= { status: null };
      result.status = null;
      const primary = result.error;
      result.error = new Error('supervisor helper cleanup failed: ' + error.message, { cause: primary });
      if (primary?.code) result.error.code = primary.code;
    }
    if (!result?.error?.message?.startsWith('supervisor helper cleanup failed:')) await rm(directory, { recursive: true, force: true });
  }
  return result;
}
