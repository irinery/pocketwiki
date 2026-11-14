import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectLinuxExecutable } from './MacOSHost/managed-helpers.mjs';

const missing = () => Object.assign(new Error('missing'), { code: 'ENOENT' });
const denied = () => Object.assign(new Error('denied'), { code: 'EACCES' });
for (const point of ['exe', 'cmdline']) {
  for (const [name, state, stopped] of [
    ['absent', { status: 1, stdout: '' }, true],
    ['zombie', { status: 0, stdout: 'Z\n' }, true],
    ['alive', { status: 0, stdout: 'S\n' }, false],
    ['ps failure', { status: 2, stdout: '' }, false]
  ]) {
    test(`${point} ENOENT accepts only absent/zombie: ${name}`, () => {
      const deps = {
        readlink: () => { if (point === 'exe') throw missing(); return '/usr/bin/dash'; },
        readFile: () => { throw missing(); },
        realpath: () => '/usr/bin/dash',
        ps: () => state
      };
      if (stopped) assert.equal(inspectLinuxExecutable(123, '/private/launcher', deps), null);
      else assert.throws(() => inspectLinuxExecutable(123, '/private/launcher', deps), /cannot (inspect|recheck)/);
    });
  }
  test(`${point} EACCES fails closed even if process is zombie`, () => {
    const deps = {
      readlink: () => { if (point === 'exe') throw denied(); return '/usr/bin/dash'; },
      readFile: () => { throw denied(); },
      realpath: () => '/usr/bin/dash', ps: () => ({ status: 0, stdout: 'Z\n' })
    };
    assert.throws(() => inspectLinuxExecutable(123, '/private/launcher', deps), /cannot inspect/);
  });
}
