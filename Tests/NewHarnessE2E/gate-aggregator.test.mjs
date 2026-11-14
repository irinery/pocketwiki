import test from 'node:test';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import matrix from '../../docs/rfcs/new-harness/matriz-verificacao.json' with { type: 'json' };
import { aggregateReportFiles, aggregateReports, targetIdentity, assertSameIdentity } from './gate-aggregator.mjs';

const sha1 = 'a'.repeat(40);
const sha256 = 'b'.repeat(64);
const identity = {
  version: '0.2.0', stage: 'E0',
  pocketwiki_sha: sha1, pocketkernel_sha: 'c'.repeat(40), middlewareauth_sha: 'd'.repeat(40),
  schema_sha256: sha256, fixture_sha256: 'c'.repeat(64), matrix_sha256: 'd'.repeat(64),
  seed: 20261102, auth_mode: 'host_local', exit_code: 0
};
function reports() {
  return [
    { ...identity, cases: [{ id: 'CONTRACT-00', surface: 'service', status: 'passed', artifact_paths: ['service/junit.xml'] }] },
    { ...identity, cases: [{ id: 'LEGACY-00', surface: 'web', status: 'passed', artifact_paths: ['web/trace.zip'] }] },
    { ...identity, cases: [{ id: 'LEGACY-00', surface: 'macos', status: 'passed', artifact_paths: ['macos/junit.xml'] }] }
  ];
}

test('E0 aggregator emits gate_passed only for the complete required matrix', () => {
  const result = aggregateReports('E0', reports(), matrix);
  assert.equal(result.gate_passed, true);
  assert.equal(result.cases.length, 3);
});

test('aggregator rejects a missing surface pair', () => {
  assert.throws(() => aggregateReports('E0', reports().slice(0, 2), matrix), /missing required/);
});

test('aggregator rejects failed, skipped, duplicate and unexpected cases', () => {
  for (const status of ['failed', 'skipped']) {
    const input = reports(); input[0].cases[0].status = status;
    assert.throws(() => aggregateReports('E0', input, matrix), /not passed/);
  }
  const input = reports(); input.push(structuredClone(input[0]));
  assert.throws(() => aggregateReports('E0', input, matrix), /duplicate/);
  const unexpected = reports(); unexpected[0].cases[0].surface = 'macos';
  assert.throws(() => aggregateReports('E0', unexpected, matrix), /unexpected/);
});

test('aggregator rejects divergent SHAs, hashes and forbidden authentication modes', () => {
  const shaMismatch = reports(); shaMismatch[1].pocketkernel_sha = 'f'.repeat(40);
  assert.throws(() => aggregateReports('E0', shaMismatch, matrix), /divergent pocketkernel_sha/);
  const digestMismatch = reports(); digestMismatch[2].fixture_sha256 = 'f'.repeat(64);
  assert.throws(() => aggregateReports('E0', digestMismatch, matrix), /divergent fixture_sha256/);
  const auth = reports(); auth[2].auth_mode = 'fixture';
  assert.throws(() => aggregateReports('E0', auth, matrix), /divergent auth_mode/);
  const seed = reports(); seed[2].seed += 1;
  assert.throws(() => aggregateReports('E0', seed, matrix), /divergent seed/);
  const invalidSeed = reports(); invalidSeed[2].seed = Number.MAX_SAFE_INTEGER + 1;
  assert.throws(() => aggregateReports('E0', invalidSeed, matrix), /invalid or missing seed/);
  const forbiddenAuth = reports(); forbiddenAuth[2].auth_mode = 'real';
  assert.throws(() => aggregateReports('E0', forbiddenAuth, matrix), /divergent auth_mode/);
});

test('aggregator rejects a non-zero shard exit and unsafe artifacts', () => {
  const failed = reports(); failed[0].exit_code = 2;
  assert.throws(() => aggregateReports('E0', failed, matrix), /exit_code/);
  const unsafe = reports(); unsafe[0].cases[0].artifact_paths = ['/tmp/junit.xml'];
  assert.throws(() => aggregateReports('E0', unsafe, matrix), /safe relative/);
  const traversal = reports(); traversal[0].cases[0].artifact_paths = ['service/../secret.log'];
  assert.throws(() => aggregateReports('E0', traversal, matrix), /safe relative/);
  const emptyArtifacts = reports(); emptyArtifacts[0].cases[0].artifact_paths = [];
  assert.throws(() => aggregateReports('E0', emptyArtifacts, matrix), /safe relative/);
  const invalidPair = reports(); invalidPair[0].cases[0].id = '';
  assert.throws(() => aggregateReports('E0', invalidPair, matrix), /invalid case identity/);
});

test('file aggregator requires real artifacts contained in each report directory', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'nh-gate-aggregator-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const files = [];
  for (const [index, report] of reports().entries()) {
    const directory = path.join(root, 'shard-' + index);
    await mkdir(path.join(directory, 'artifacts'), { recursive: true });
    report.cases[0].artifact_paths = ['artifacts/result.txt'];
    await writeFile(path.join(directory, 'artifacts/result.txt'), 'redacted evidence\n');
    const reportPath = path.join(directory, 'report.json');
    await writeFile(reportPath, JSON.stringify(report));
    files.push(reportPath);
  }
  assert.equal((await aggregateReportFiles('E0', files, identity)).gate_passed, true);
  await assert.rejects(() => aggregateReportFiles('E0', files), /target build identity/);
  for (const field of ['pocketwiki_sha', 'pocketkernel_sha', 'middlewareauth_sha', 'schema_sha256', 'fixture_sha256', 'matrix_sha256']) {
    const target = { ...identity, [field]: 'f'.repeat(identity[field].length) };
    await assert.rejects(() => aggregateReportFiles('E0', files, target), new RegExp('target build mismatch: ' + field));
  }


  const missing = path.join(path.dirname(files[0]), 'missing.json');
  const missingReport = reports()[0];
  missingReport.cases[0].artifact_paths = ['artifacts/missing.txt'];
  await writeFile(missing, JSON.stringify(missingReport));
  await assert.rejects(() => aggregateReportFiles('E0', [missing, ...files.slice(1)], identity), /artifact does not exist/);

  const outside = path.join(root, 'outside.txt');
  await writeFile(outside, 'must not be accepted');
  const linked = path.join(path.dirname(files[0]), 'artifacts', 'outside.txt');
  await symlink(outside, linked);
  const linkedReport = reports()[0];
  linkedReport.cases[0].artifact_paths = ['artifacts/outside.txt'];
  const linkedPath = path.join(path.dirname(files[0]), 'linked.json');
  await writeFile(linkedPath, JSON.stringify(linkedReport));
  await assert.rejects(() => aggregateReportFiles('E0', [linkedPath, ...files.slice(1)], identity), /artifact must be a regular file inside/);
});

test('target identity hashes real checkout files and rejects wrong or dirty checkouts', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'nh-target-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const repos = ['wiki', 'kernel', 'middleware'].map((name) => path.join(root, name));
  for (const repo of repos) {
    await mkdir(repo);
    execFileSync('git', ['init', '-q', repo]);
    await writeFile(path.join(repo, 'tracked'), path.basename(repo));
  }
  const files = [
    'src/harness/contracts/corpus-v1.json', 'src/harness/contracts/operation-registry.json',
    'Tests/Harness/nh00-acceptance-regressions.json', 'docs/rfcs/new-harness/manifest.json',
    'src/harness/contracts/harness-v1.schema.json', 'docs/rfcs/new-harness/matriz-verificacao.json'
  ];
  for (const file of files) {
    await mkdir(path.dirname(path.join(repos[0], file)), { recursive: true });
    await writeFile(path.join(repos[0], file), file);
  }
  for (const repo of repos) {
    execFileSync('git', ['-C', repo, 'add', '.']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture']);
  }
  const sha = execFileSync('git', ['-C', repos[0], 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  const actual = await targetIdentity(...repos, sha);
  assert.equal(actual.pocketwiki_sha, sha);
  assert.match(actual.fixture_sha256, /^[a-f0-9]{64}$/);
  await assert.rejects(() => targetIdentity(...repos, 'f'.repeat(40)), /target SHA differs/);
  await writeFile(path.join(repos[0], files[0]), 'changed');
  await assert.rejects(() => targetIdentity(...repos, sha), /modified tracked files/);
  execFileSync('git', ['-C', repos[0], 'add', '.']);
  execFileSync('git', ['-C', repos[0], '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'changed during execution']);
  const changedSHA = execFileSync('git', ['-C', repos[0], 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  await assert.rejects(() => targetIdentity(...repos, sha), /target SHA differs/);
  const changed = await targetIdentity(...repos, changedSHA);
  assert.throws(() => assertSameIdentity(actual, changed), /target build mismatch/);

});
