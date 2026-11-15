import test from 'node:test';
import { replayProofSHA256, canonicalJSON } from './replay-proof.mjs';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import matrix from '../../docs/rfcs/new-harness/matriz-verificacao.json' with { type: 'json' };
import { aggregateReportFiles, aggregateReports, targetIdentity, assertSameIdentity, assertPinnedDependencies, fixtureDigest } from './gate-aggregator.mjs';

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
  await writeFile(path.join(repos[0], 'docs/rfcs/new-harness/fixture-hashes-v1.json'), JSON.stringify({ version: 1, stages: { E0: files.slice(0, 4), E1: ['src/harness/contracts/harness-v1.schema.json'] } }));
  for (const repo of repos) {
    execFileSync('git', ['-C', repo, 'add', '.']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture']);
  }
  const sha = execFileSync('git', ['-C', repos[0], 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  const actual = await targetIdentity(...repos, sha, 'E0');
  assert.equal(actual.pocketwiki_sha, sha);
  assert.match(actual.fixture_sha256, /^[a-f0-9]{64}$/);
  await assert.rejects(() => targetIdentity(...repos, sha), /stage must/);
  assert.equal(actual.fixture_sha256, await fixtureDigest(repos[0], 'E0'));
  assert.equal((await targetIdentity(...repos, sha, 'E1')).fixture_sha256, await fixtureDigest(repos[0], 'E1'));
  assert.notEqual(actual.fixture_sha256, (await targetIdentity(...repos, sha, 'E1')).fixture_sha256);
  execFileSync('git', ['-C', repos[0], 'update-index', '--skip-worktree', files[0]]);
  await writeFile(path.join(repos[0], files[0]), 'hidden change');
  await assert.rejects(() => targetIdentity(...repos, sha, 'E0'), /skip-worktree/);
  execFileSync('git', ['-C', repos[0], 'update-index', '--no-skip-worktree', files[0]]);
  execFileSync('git', ['-C', repos[0], 'restore', '--', files[0]]);
  execFileSync('git', ['-C', repos[0], 'update-index', '--assume-unchanged', files[0]]);
  await assert.rejects(() => targetIdentity(...repos, sha, 'E0'), /assume-unchanged/);
  execFileSync('git', ['-C', repos[0], 'update-index', '--no-assume-unchanged', files[0]]);
  await assert.rejects(() => targetIdentity(...repos, 'f'.repeat(40), 'E0'), /target SHA differs/);
  await writeFile(path.join(repos[0], files[0]), 'changed');
  await assert.rejects(() => targetIdentity(...repos, sha, 'E0'), /modified tracked files/);
  execFileSync('git', ['-C', repos[0], 'add', '.']);
  execFileSync('git', ['-C', repos[0], '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'changed during execution']);
  const changedSHA = execFileSync('git', ['-C', repos[0], 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  await assert.rejects(() => targetIdentity(...repos, sha, 'E0'), /target SHA differs/);
  const changed = await targetIdentity(...repos, changedSHA, 'E0');
  assert.throws(() => assertSameIdentity(actual, changed), /target build mismatch/);

});


test('E1 requires all six cumulative pairs and validates replay artifact bindings', async t => {
  const input = reports().map(report => ({ ...report, stage: 'E1' }));
  input[0].cases.push({ id: 'SERVICE-0002', surface: 'service', status: 'passed', artifact_paths: ['service/runtime.log'] });
  input[1].cases.push({ id: 'UI-0002', surface: 'web', status: 'passed', artifact_paths: ['web/runtime.log'] });
  input[2].cases.push({ id: 'UI-0002', surface: 'macos', status: 'passed', artifact_paths: ['macos/runtime.log'] });
  assert.throws(() => aggregateReports('E1', input, matrix), /invalid integrated replay/);
  for (const [index, surface] of [[1, 'web'], [2, 'macos']]) {
    const nonce = 'a'.repeat(32), state = seq => ({ revision: 1, lastSeq: seq, receipts: {}, effects: {} });
    const digest = data => replayProofSHA256(Buffer.from(canonicalJSON(data)));
    const frame = (seq, after) => ({ seq, before_cursor: 10, after_cursor: after, before_state: state(10), after_state: state(after), before: digest(state(10)), after: digest(state(after)) });
    const proof = { version: 1, level: 'integration', surface, nonce, boundary: 10, frames: [frame(9, 10), frame(10, 10), frame(11, 11)] };
    Object.assign(input[index].cases[1], { replay_proof: proof, replay_nonce: nonce, replay_proof_sha256: replayProofSHA256(Buffer.from(JSON.stringify(proof))), replay_proof_path: surface + '/proof.json', replay_host_path: surface + '/result.json' });
    input[index].cases[1].artifact_paths.push(surface + '/proof.json', surface + '/result.json');
  }
  assert.equal(aggregateReports('E1', input, matrix).gate_passed, true);
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-replay-proof-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const paths = [];
  for (const [index, report] of input.entries()) {
    for (const item of report.cases) for (const artifact of item.artifact_paths) {
      const target = path.join(dir, artifact); await mkdir(path.dirname(target), { recursive: true });
      let content = 'fixture';
      if (artifact === item.replay_proof_path) content = JSON.stringify(item.replay_proof);
      if (artifact === item.replay_host_path) content = JSON.stringify({ surface: item.surface, cases: ['02-01', '02-02', '02-03', '02-04'].map(id => ({ id, status: 'passed', ...(id === '02-01' ? { replay_nonce: item.replay_nonce, replay_proof_sha256: item.replay_proof_sha256 } : {}) })) });
      await writeFile(target, content);
    }
    // Equivalent JSON in a different property order still matches the exact hashed artifact.
    for (const item of report.cases) if (item.replay_proof) item.replay_proof = Object.fromEntries(Object.entries(item.replay_proof).reverse());
    const reportPath = path.join(dir, `shard-${index}.json`); await writeFile(reportPath, JSON.stringify(report)); paths.push(reportPath);
  }
  assert.equal((await aggregateReportFiles('E1', paths, identity)).gate_passed, true);
  for (const surface of ['web', 'macos']) {
    const file = path.join(dir, surface, 'result.json');
    const valid = JSON.parse(await readFile(file, 'utf8'));
    for (const mutate of [
      host => { host.cases[1].status = 'failed'; },
      host => { host.cases.pop(); },
      host => { host.cases[1] = { ...host.cases[0] }; },
      host => { host.invalidated = true; },
      host => { host.cases[2].invalidated = true; },
      host => { host.surface = surface === 'web' ? 'macos' : 'web'; }
    ]) {
      const host = structuredClone(valid); mutate(host); await writeFile(file, JSON.stringify(host));
      await assert.rejects(() => aggregateReportFiles('E1', paths, identity), /replay host artifact mismatch/);
    }
    await writeFile(file, JSON.stringify(valid));
  }
  await writeFile(path.join(dir, 'web/proof.json'), '{}');
  await assert.rejects(() => aggregateReportFiles('E1', paths, identity), /replay proof artifact mismatch/);

  const badBoundary = structuredClone(input); badBoundary[1].cases[1].replay_proof.boundary = 9;
  assert.throws(() => aggregateReports('E1', badBoundary, matrix), /invalid integrated replay/);
  const badLevel = structuredClone(input); badLevel[1].cases[1].replay_proof.level = 'unit';
  assert.throws(() => aggregateReports('E1', badLevel, matrix), /invalid integrated replay/);
  const missing = structuredClone(input); missing[2].cases.pop();
  assert.throws(() => aggregateReports('E1', missing, matrix), /missing required.*UI-0002\/macos/);
  const duplicate = structuredClone(input); duplicate[0].cases.push(structuredClone(duplicate[0].cases[1]));
  assert.throws(() => aggregateReports('E1', duplicate, matrix), /duplicate/);
  const stale = structuredClone(input); stale[0].pocketkernel_sha = 'e'.repeat(40);
  assert.throws(() => aggregateReports('E1', stale, matrix), /divergent pocketkernel_sha/);
});


test('active dependency pins are mandatory and exact', () => {
  const pins = 'PocketKernel: `' + identity.pocketkernel_sha + '`\nMiddlewareAuth: `' + identity.middlewareauth_sha + '`';
  assert.doesNotThrow(() => assertPinnedDependencies(identity, pins));
  assert.throws(() => assertPinnedDependencies({ ...identity, pocketkernel_sha: 'f'.repeat(40) }, pins), /pin mismatch/);
  assert.throws(() => assertPinnedDependencies(identity, ''), /pin mismatch/);
});
