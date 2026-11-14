import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fixtureDigest } from './gate-aggregator.mjs';

const manifestPath = 'docs/rfcs/new-harness/fixture-hashes-v1.json';
test('cumulative fixture digest detects changes to every declared fixture', async t => {
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const root = await mkdtemp(path.join(os.tmpdir(), 'nh-fixture-digest-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const all = [...manifest.stages.E0, ...manifest.stages.E1];
  assert.equal(new Set(all).size, all.length);
  for (const name of [manifestPath, ...all]) await mkdir(path.dirname(path.join(root, name)), { recursive: true });
  await writeFile(path.join(root, manifestPath), JSON.stringify(manifest));
  for (const name of all) await writeFile(path.join(root, name), 'fixture bytes: ' + name);
  const e0 = await fixtureDigest(root, 'E0'), e1 = await fixtureDigest(root, 'E1');
  assert.notEqual(e0, e1);
  for (const name of all) {
    const file = path.join(root, name), original = await readFile(file);
    await writeFile(file, Buffer.concat([original, Buffer.from('!')]));
    assert.notEqual(await fixtureDigest(root, 'E1'), e1, name);
    if (manifest.stages.E1.includes(name)) assert.equal(await fixtureDigest(root, 'E0'), e0, name);
    await writeFile(file, original);
  }
  const reversed = structuredClone(manifest);
  reversed.stages.E0.reverse(); reversed.stages.E1.reverse();
  await writeFile(path.join(root, manifestPath), JSON.stringify(reversed));
  assert.equal(await fixtureDigest(root, 'E1'), e1, 'ordering is canonical');
  await rm(path.join(root, manifest.stages.E1[0]));
  await assert.rejects(fixtureDigest(root, 'E1'), { code: 'ENOENT' });
});

test('fixture manifest rejects traversal, duplicates and symlink files', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'nh-fixture-path-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, 'docs/rfcs/new-harness'), { recursive: true });
  const manifestFile = path.join(root, manifestPath);
  const write = stages => writeFile(manifestFile, JSON.stringify({ version: 1, stages }));
  await write({ E0: ['../outside'], E1: ['other'] });
  await assert.rejects(fixtureDigest(root, 'E1'), /invalid or duplicate/);
  await write({ E0: ['same'], E1: ['same'] });
  await assert.rejects(fixtureDigest(root, 'E1'), /invalid or duplicate/);
  await write({ E0: ['link'], E1: ['other'] });
  await symlink('/etc/passwd', path.join(root, 'link'));
  await assert.rejects(fixtureDigest(root, 'E0'), /regular file/);
});
