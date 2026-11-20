import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { DEFAULT_FIXTURE_SEED, fixtureUUID, parseFixtureSeed } from '../Harness/runtime/fixture-identities.mjs';

const labels = ['principal', 'environment', 'thread', 'other-principal', 'denied-command', 'first-command', 'second-command', 'crash-command'];
test('fixture IDs reproduce across processes for the reported seed', () => {
  const expected = labels.map(label => fixtureUUID(DEFAULT_FIXTURE_SEED, label));
  const program = "import {fixtureUUID} from './Tests/Harness/runtime/fixture-identities.mjs'; console.log(JSON.stringify(JSON.parse(process.argv[1]).map(label => fixtureUUID(Number(process.argv[2]), label))));";
  const run = seed => spawnSync(process.execPath, ['--input-type=module', '-e', program, JSON.stringify(labels), String(seed)], { encoding: 'utf8' });
  const first = run(DEFAULT_FIXTURE_SEED), second = run(DEFAULT_FIXTURE_SEED), other = run(DEFAULT_FIXTURE_SEED + 1);
  for (const result of [first, second, other]) assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(first.stdout), expected);
  assert.deepEqual(JSON.parse(second.stdout), expected);
  assert.notDeepEqual(JSON.parse(other.stdout), expected);
  assert.equal(new Set(expected).size, labels.length);
  for (const id of expected) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('fixture seed parsing is strict and rejects unsafe integers', () => {
  assert.equal(parseFixtureSeed(), DEFAULT_FIXTURE_SEED);
  assert.equal(parseFixtureSeed('0'), 0);
  for (const value of ['', '-1', '01', '1.0', 'NaN', '9007199254740992']) assert.throws(() => parseFixtureSeed(value));
});
