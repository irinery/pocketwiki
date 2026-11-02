import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import matrix from '../../docs/rfcs/new-harness/matriz-verificacao.json' with { type: 'json' };
import { aggregateReportFiles, aggregateReports } from './gate-aggregator.mjs';

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
  assert.equal((await aggregateReportFiles('E0', files)).gate_passed, true);

  const missing = path.join(path.dirname(files[0]), 'missing.json');
  const missingReport = reports()[0];
  missingReport.cases[0].artifact_paths = ['artifacts/missing.txt'];
  await writeFile(missing, JSON.stringify(missingReport));
  await assert.rejects(() => aggregateReportFiles('E0', [missing, ...files.slice(1)]), /artifact does not exist/);

  const outside = path.join(root, 'outside.txt');
  await writeFile(outside, 'must not be accepted');
  const linked = path.join(path.dirname(files[0]), 'artifacts', 'outside.txt');
  await symlink(outside, linked);
  const linkedReport = reports()[0];
  linkedReport.cases[0].artifact_paths = ['artifacts/outside.txt'];
  const linkedPath = path.join(path.dirname(files[0]), 'linked.json');
  await writeFile(linkedPath, JSON.stringify(linkedReport));
  await assert.rejects(() => aggregateReportFiles('E0', [linkedPath, ...files.slice(1)]), /artifact must be a regular file inside/);
});
