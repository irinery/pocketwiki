import { validateReplayProof, replayProofSHA256, canonicalJSON } from './replay-proof.mjs';
import { assertTrackedFlags } from './git-snapshot.mjs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const matrixPath = path.resolve(here, '../../docs/rfcs/new-harness/matriz-verificacao.json');
const hashFields = ['pocketwiki_sha', 'pocketkernel_sha', 'middlewareauth_sha'];
const digestFields = ['schema_sha256', 'fixture_sha256', 'matrix_sha256'];

// The UI host observes these fields before and after its own execution.
export function assertUIHostIdentity(host, expected) {
  const fields = ['pocketwiki_sha', 'pocketkernel_sha', 'middlewareauth_sha', 'schema_sha256', 'seed', 'auth_mode'];
  for (const field of fields) {
    if (host?.[field] !== expected?.[field] || host?.after?.[field] !== expected?.[field] || expected?.[field] === undefined) {
      throw new Error('UI host identity mismatch: ' + field);
    }
  }
}

export async function aggregateReportFiles(stage, reportPaths, target) {
  if (!target) throw new Error('target build identity is required');
  const matrix = JSON.parse(await readFile(matrixPath, 'utf8'));
  const reports = await Promise.all(reportPaths.map(async (file) => {
    const reportPath = path.resolve(file);
    const report = JSON.parse(await readFile(reportPath, 'utf8'));
    await verifyArtifacts(reportPath, report);
    return report;
  }));
  const result = aggregateReports(stage, reports, matrix);
  assertSameIdentity(target, result);
  return result;
}

export function aggregateReports(stage, reports, matrix) {
  const targetStage = parseStage(stage);
  if (!Array.isArray(reports) || reports.length === 0) throw new Error('at least one shard report is required');

  const expected = new Map();
  for (const scenario of matrix.cases.filter((item) => item.stage <= targetStage)) {
    for (const surface of scenario.surfaces) expected.set(scenario.id + '/' + surface, scenario);
  }
  if (expected.size === 0) throw new Error('no matrix cases exist for stage ' + stage);

  const identity = {};
  for (const field of [...hashFields, ...digestFields, 'seed', 'auth_mode']) {
    const values = new Set();
    for (const report of reports) {
      const value = report[field];
      if (hashFields.includes(field) || digestFields.includes(field)) {
        const pattern = hashFields.includes(field) ? /^[a-f0-9]{40}$/i : /^[a-f0-9]{64}$/i;
        if (typeof value !== 'string' || !pattern.test(value)) throw new Error('invalid or missing ' + field);
        values.add(value.toLowerCase());
      } else if (field === 'seed') {
        if (!Number.isSafeInteger(value) || value < 0) throw new Error('invalid or missing seed');
        values.add(value);
      } else {
        if (!['host_local', 'fixture', 'real'].includes(value)) throw new Error('invalid or missing auth_mode');
        values.add(value);
      }
    }
    if (values.size !== 1) throw new Error('divergent ' + field + ' across shard reports');
    identity[field] = [...values][0];
  }

  const actual = new Map();
  for (const report of reports) {
    if (report.version !== '0.2.0') throw new Error('unsupported report version');
    if (report.stage !== stage) throw new Error('report stage does not match requested stage');
    if (report.exit_code !== 0) throw new Error('shard exit_code is not zero');
    if (!Array.isArray(report.cases)) throw new Error('report cases must be an array');
    for (const result of report.cases) {
      if (!result || typeof result.id !== 'string' || result.id.trim().length === 0 || !['service', 'web', 'macos'].includes(result.surface)) {
        throw new Error('invalid case identity');
      }
      const key = result.id + '/' + result.surface;
      const scenario = expected.get(key);
      if (!scenario) throw new Error('unexpected scenario/surface pair ' + key);
      if (actual.has(key)) throw new Error('duplicate scenario/surface pair ' + key);
      if (result.status !== 'passed') throw new Error('case is not passed (skip/failure is forbidden): ' + key);
      if (!Array.isArray(result.artifact_paths) || result.artifact_paths.length === 0 || result.artifact_paths.some((item) => !isSafeRelativePath(item))) {
        throw new Error('artifact_paths must be safe relative paths: ' + key);
      }
      if (result.id === 'UI-0002') {
        validateReplayProof(result.replay_proof, { surface: result.surface, nonce: result.replay_nonce });
        if (!isSafeRelativePath(result.replay_proof_path) || !result.artifact_paths.includes(result.replay_proof_path) || !isSafeRelativePath(result.replay_host_path) || !result.artifact_paths.includes(result.replay_host_path) || !isSafeRelativePath(result.replay_identity_path) || !result.artifact_paths.includes(result.replay_identity_path) || !/^[a-f0-9]{64}$/.test(result.replay_proof_sha256 || '')) throw new Error('invalid replay proof artifact binding: ' + key);
      }
      if (scenario.stage <= 2 && report.auth_mode !== 'host_local') {
        throw new Error('forbidden auth_mode for ' + key + ': ' + report.auth_mode);
      }
      actual.set(key, result);
    }
  }

  const missing = [...expected.keys()].filter((key) => !actual.has(key));
  if (missing.length) throw new Error('missing required scenario/surface pairs: ' + missing.join(', '));
  // No E2 service currently has a verifier that binds every RFC scenario to
  // the real service. A passed status and an existing log are not such proof.
  // Keep this closed until an independently reviewed verifier is implemented.
  const unverifiedServices = [...expected.entries()]
    .filter(([, scenario]) => scenario.stage >= 2 && scenario.kind === 'service-integration')
    .map(([key]) => key);
  if (unverifiedServices.length) throw new Error('service evidence verifier unavailable: ' + unverifiedServices.join(', '));

  return {
    version: '0.2.0',
    stage,
    gate_passed: true,
    ...identity,
    cases: [...actual.entries()].map(([key, result]) => ({ key, status: result.status, artifact_paths: result.artifact_paths }))
  };
}

export function assertPinnedDependencies(identity, text) {
  for (const [label, field] of [['PocketKernel', 'pocketkernel_sha'], ['MiddlewareAuth', 'middlewareauth_sha']]) {
    const match = text.match(new RegExp(label + ': `([a-f0-9]{40})`'));
    if (!match || identity[field] !== match[1]) throw new Error('dependency pin mismatch: ' + label);
  }
}

export function assertSameIdentity(expected, actual) {
  for (const field of [...hashFields, ...digestFields]) {
    if (expected[field] !== actual[field]) throw new Error('target build mismatch: ' + field);
  }
}

// Identity is computed from clean checkouts, including the exact files consumed by the runner.
export async function targetIdentity(wiki, kernel, middleware, expectedSHA, stage) {
  function checkedSHA(repo, label) {
    assertTrackedFlags(repo);
    const run = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim();
    const sha = run('rev-parse', 'HEAD').toLowerCase();
    if (run('status', '--porcelain=v1', '--untracked-files=no')) throw new Error(label + ' checkout has modified tracked files');
    return sha;
  }
  if (!/^[a-f0-9]{40}$/.test(expectedSHA || '')) throw new Error('target SHA must be a full lowercase SHA');
  const identity = {
    pocketwiki_sha: checkedSHA(wiki, 'PocketWiki'),
    pocketkernel_sha: checkedSHA(kernel, 'PocketKernel'),
    middlewareauth_sha: checkedSHA(middleware, 'MiddlewareAuth')
  };
  if (identity.pocketwiki_sha !== expectedSHA) throw new Error('target SHA differs from PocketWiki checkout');
  identity.fixture_sha256 = await fixtureDigest(wiki, stage, { requireTracked: true });
  for (const [field, file] of [
    ['schema_sha256', 'src/harness/contracts/harness-v1.schema.json'],
    ['matrix_sha256', 'docs/rfcs/new-harness/matriz-verificacao.json']
  ]) identity[field] = createHash('sha256').update(await readFile(path.join(wiki, file))).digest('hex');
  return identity;
}

// Versioned, cumulative fixture manifest. Length framing prevents path/content ambiguity.
export async function fixtureDigest(wiki, stage, { requireTracked = false } = {}) {
  const stageNumber = parseStage(stage);
  const root = await realpath(wiki);
  const manifestName = 'docs/rfcs/new-harness/fixture-hashes-v1.json';
  await assertRegularFixture(root, manifestName);
  const manifest = JSON.parse(await readFile(path.join(root, manifestName), 'utf8'));
  if (!manifest || manifest.version !== 1 || !manifest.stages || typeof manifest.stages !== 'object' || Array.isArray(manifest.stages)) throw new Error('invalid fixture manifest');
  const stages = Object.keys(manifest.stages);
  if (stages.some(key => !/^E[0-6]$/.test(key))) throw new Error('invalid fixture manifest stages');
  for (let index = 0; index <= stageNumber; index += 1) {
    const requiredStage = 'E' + index;
    if (!stages.includes(requiredStage)) throw new Error('missing fixture manifest stage: ' + requiredStage);
  }
  if (!stages.includes('E0') || !stages.includes('E1')) throw new Error('invalid fixture manifest stages');
  const all = new Set(), selected = [];
  for (const key of stages.sort((a, b) => parseStage(a) - parseStage(b))) {
    if (!Array.isArray(manifest.stages[key]) || manifest.stages[key].length === 0) throw new Error('empty fixture manifest stage: ' + key);
    for (const file of manifest.stages[key]) {
      if (!isSafeRelativePath(file) || all.has(file)) throw new Error('invalid or duplicate fixture path: ' + String(file));
      all.add(file);
      if (parseStage(key) <= stageNumber) selected.push(file);
    }
  }
  selected.sort((a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8')));
  const hash = createHash('sha256');
  hash.update('pocketwiki-fixtures\0v1\0' + stage + '\0');
  const frame = bytes => { const size = Buffer.alloc(8); size.writeBigUInt64BE(BigInt(bytes.length)); hash.update(size); hash.update(bytes); };
  if (requireTracked) {
    for (const file of [manifestName, ...selected]) {
      try {
        execFileSync('git', ['-C', root, 'ls-files', '--error-unmatch', '--', file], { stdio: 'ignore' });
      } catch { throw new Error('fixture manifest and files must be tracked: ' + file); }
    }
  }
  for (const file of selected) {
    await assertRegularFixture(root, file);
    const candidate = path.join(root, file);
    frame(Buffer.from(file, 'utf8')); frame(await readFile(candidate));
  }
  return hash.digest('hex');
}

async function assertRegularFixture(root, file) {
  let component = root;
  for (const segment of file.split('/')) {
    component = path.join(component, segment);
    if ((await lstat(component)).isSymbolicLink()) throw new Error('fixture must be a regular file inside checkout: ' + file);
  }
  const info = await lstat(component), resolved = await realpath(component);
  if (!info.isFile() || !resolved.startsWith(root + path.sep)) throw new Error('fixture must be a regular file inside checkout: ' + file);
}

function isSafeRelativePath(value) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\\') || value.includes('\0')) return false;
  if (path.posix.isAbsolute(value) || path.win32.isAbsolute(value) || /^[a-zA-Z]:/.test(value)) return false;
  const segments = value.split('/');
  return segments.every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

async function verifyArtifacts(reportPath, report) {
  if (!report || !Array.isArray(report.cases)) throw new Error('report cases must be an array');
  const reportDirectory = await realpath(path.dirname(reportPath));
  for (const result of report.cases) {
    if (result.id === 'UI-0002') {
      if (!isSafeRelativePath(result.replay_proof_path) || !result.artifact_paths?.includes(result.replay_proof_path)) throw new Error('invalid replay proof artifact binding');
      const proofPath = path.resolve(reportDirectory, ...result.replay_proof_path.split('/'));
      const resolved = await realpath(proofPath), metadata = await lstat(proofPath);
      if (!resolved.startsWith(reportDirectory + path.sep) || !metadata.isFile() || metadata.isSymbolicLink()) throw new Error('invalid replay proof file');
      if (!isSafeRelativePath(result.replay_identity_path) || !result.artifact_paths.includes(result.replay_identity_path)) throw new Error('invalid UI host identity artifact binding');
      const identityPath = path.resolve(reportDirectory, ...result.replay_identity_path.split('/'));
      const identityResolved = await realpath(identityPath), identityMetadata = await lstat(identityPath);
      if (!identityResolved.startsWith(reportDirectory + path.sep) || !identityMetadata.isFile() || identityMetadata.isSymbolicLink()) throw new Error('invalid UI host identity file');
      assertUIHostIdentity(JSON.parse(await readFile(identityPath, 'utf8')), report);
      if (!isSafeRelativePath(result.replay_host_path) || !result.artifact_paths.includes(result.replay_host_path)) throw new Error('invalid replay host artifact binding');
      const hostPath = path.resolve(reportDirectory, ...result.replay_host_path.split('/'));
      const hostResolved = await realpath(hostPath), hostMetadata = await lstat(hostPath);
      if (!hostResolved.startsWith(reportDirectory + path.sep) || !hostMetadata.isFile() || hostMetadata.isSymbolicLink()) throw new Error('invalid replay host file');
      const host = JSON.parse(await readFile(hostPath, 'utf8'));
      const required = ['02-01', '02-02', '02-03', '02-04'];
      if (host.surface !== result.surface || host.invalidated === true || !Array.isArray(host.cases) || host.cases.length !== required.length ||
          !required.every(id => host.cases.filter(row => row?.id === id && row.status === 'passed' && row.invalidated !== true).length === 1)) throw new Error('replay host artifact mismatch');
      const row = host.cases.find(item => item.id === '02-01');
      if (row.replay_nonce !== result.replay_nonce || row.replay_proof_sha256 !== result.replay_proof_sha256) throw new Error('replay host artifact mismatch');
      const bytes = await readFile(proofPath);
      if (replayProofSHA256(bytes) !== result.replay_proof_sha256 || canonicalJSON(JSON.parse(bytes)) !== canonicalJSON(result.replay_proof)) throw new Error('replay proof artifact mismatch');
    }
    if (!Array.isArray(result.artifact_paths)) throw new Error('artifact_paths must be an array');
    for (const relativePath of result.artifact_paths) {
      if (!isSafeRelativePath(relativePath)) throw new Error('unsafe artifact path: ' + String(relativePath));
      const candidate = path.resolve(reportDirectory, ...relativePath.split('/'));
      let resolved;
      let metadata;
      try {
        resolved = await realpath(candidate);
        metadata = await lstat(candidate);
      } catch {
        throw new Error('artifact does not exist: ' + relativePath);
      }
      if (!resolved.startsWith(reportDirectory + path.sep) || !metadata.isFile() || metadata.isSymbolicLink()) {
        throw new Error('artifact must be a regular file inside the report directory: ' + relativePath);
      }
    }
  }
}

function parseStage(stage) {
  const match = /^E([0-6])$/.exec(stage);
  if (!match) throw new Error('stage must be E0..E6');
  return Number(match[1]);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args[0] !== '--stage' || args[2] !== '--target-sha' || args[4] !== '--reports' || args.length < 6) throw new Error('usage: node gate-aggregator.mjs --stage E0..E6 --target-sha SHA --reports report.json [report.json ...]');
    const wiki = path.resolve(here, '../..');
    const kernel = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(wiki, '../pocketkernel-nh00');
    const middleware = process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(wiki, '../middlewareAuth');
    const target = await targetIdentity(wiki, kernel, middleware, args[3], args[1]);
    assertPinnedDependencies(target, await readFile(path.join(wiki, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8'));
    const report = await aggregateReportFiles(args[1], args.slice(5), target);
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } catch (error) {
    process.stderr.write('gate rejected: ' + error.message + '\n');
    process.exitCode = 1;
  }
}
