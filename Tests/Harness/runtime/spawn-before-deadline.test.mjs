import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnBeforeDeadline } from './spawn-before-deadline.mjs';

test('não cria subprocesso se um await termina depois do deadline', async () => {
  const controller = new AbortController();
  let release;
  const delayed = new Promise(resolve => { release = resolve; });
  let calls = 0;
  const operation = (async () => {
    await delayed;
    return spawnBeforeDeadline(controller.signal, 'fake', [], {}, () => { calls++; });
  })();
  controller.abort(new Error('deadline'));
  release();
  await assert.rejects(operation, /deadline/);
  assert.equal(calls, 0);
});

test('cria subprocesso enquanto o deadline está ativo', () => {
  const controller = new AbortController();
  const expected = {};
  let calls = 0;
  const child = spawnBeforeDeadline(controller.signal, 'fake', [], {}, () => { calls++; return expected; });
  assert.equal(child, expected);
  assert.equal(calls, 1);
});
