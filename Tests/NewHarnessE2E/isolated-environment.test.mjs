import test from 'node:test';
import assert from 'node:assert/strict';
import { userInfo } from 'node:os';
import { isolatedEnvironment } from './isolated-environment.mjs';

test('isolated environment uses the OS account and does not inherit secrets', () => {
  const env = isolatedEnvironment('/tmp/fixture-home', { PATH: '/fixture/bin', USER: 'spoofed', LOGNAME: 'spoofed', SECRET: 'private' });
  assert.equal(env.USER, userInfo().username);
  assert.equal(env.LOGNAME, userInfo().username);
  assert.equal(env.HOME, '/tmp/fixture-home');
  assert.equal(env.PATH, '/fixture/bin');
  assert.equal(env.SECRET, undefined);
  assert.equal(isolatedEnvironment('/tmp/fixture-home', {}).PATH, '/usr/bin:/bin');
});
