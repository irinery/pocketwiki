import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const matrixPath = path.resolve(here, '../../docs/rfcs/new-harness/matriz-verificacao.json');
const hashFields = ['pocketwiki_sha', 'pocketkernel_sha', 'middlewareauth_sha'];
const digestFields = ['schema_sha256', 'fixture_sha256', 'matrix_sha256'];

export async function aggregateReportFiles(stage, reportPaths) {
  const matrix = JSON.parse(await readFile(matrixPath, 'utf8'));
  const reports = await Promise.all(reportPaths.map(async (file) => {
    const reportPath = path.resolve(file);
    const report = JSON.parse(await readFile(reportPath, 'utf8'));
    await verifyArtifacts(reportPath, report);
    return report;
  }));
  return aggregateReports(stage, reports, matrix);
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
      if (scenario.stage <= 2 && report.auth_mode !== 'host_local') {
        throw new Error('forbidden auth_mode for ' + key + ': ' + report.auth_mode);
      }
      actual.set(key, result);
    }
  }

  const missing = [...expected.keys()].filter((key) => !actual.has(key));
  if (missing.length) throw new Error('missing required scenario/surface pairs: ' + missing.join(', '));
  return {
    version: '0.2.0',
    stage,
    gate_passed: true,
    ...identity,
    cases: [...actual.entries()].map(([key, result]) => ({ key, status: result.status, artifact_paths: result.artifact_paths }))
  };
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
    if (args[0] !== '--stage' || args[2] !== '--reports' || args.length < 4) throw new Error('usage: node gate-aggregator.mjs --stage E0..E6 --reports report.json [report.json ...]');
    const report = await aggregateReportFiles(args[1], args.slice(3));
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } catch (error) {
    process.stderr.write('gate rejected: ' + error.message + '\n');
    process.exitCode = 1;
  }
}
