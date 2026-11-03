import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const baseSHAs = parsePinnedSHAs(await readFile(path.join(root, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8'));
const matrixPath = path.join(root, 'docs/rfcs/new-harness/matriz-verificacao.json');
const schemaPath = path.join(root, 'src/harness/contracts/harness-v1.schema.json');
const matrix = JSON.parse(await readFile(matrixPath, 'utf8'));
const fixturePaths = [
  'src/harness/contracts/corpus-v1.json',
  'src/harness/contracts/operation-registry.json',
  'Tests/Harness/nh00-acceptance-regressions.json',
  'docs/rfcs/new-harness/manifest.json'
];
const args = parseArgs(process.argv.slice(2));
const stage = args.stage;
const surface = args.surface;
const reportDir = args.reportDir;
const stageNumber = Number(stage.slice(1));
const reportName = stage.toLowerCase() + '-' + surface + '.json';
let exitCode = 0;
let tempHome;

try {
  const selected = selectedPairs(stageNumber, surface, matrix);
  const unsupported = selected.filter(({ scenario }) => scenario.id !== 'CONTRACT-00' && scenario.id !== 'LEGACY-00');
  if (unsupported.length) throw configError('faltam dependências/handlers dos cenários: ' + unsupported.map(({ scenario }) => scenario.id).join(', '));

  await mkdir(reportDir, { recursive: true });
  tempHome = await mkdtemp(path.join(os.tmpdir(), 'nh-test-runtime-'));
  const artifactDir = path.join(reportDir, stage.toLowerCase() + '-' + surface);
  await mkdir(artifactDir, { recursive: true });

  const cases = [];
  for (const pair of selected) {
    const scenarioTimeout = pair.surface === 'web' ? 180_000 : 15 * 60_000;
    const deadline = Date.now() + scenarioTimeout;
    const id = pair.scenario.id;
    const result = id === 'CONTRACT-00'
      ? await runContract(artifactDir, tempHome, baseSHAs, deadline)
      : await runLegacy(pair.surface, artifactDir, tempHome, deadline);
    cases.push({ id, surface: pair.surface, status: result.ok ? 'passed' : 'failed', artifact_paths: result.artifacts });
    if (!result.ok) exitCode = Math.max(exitCode, result.exitCode || 1);
    if (result.configurationError) exitCode = 2;
  }

  const junitName = stage.toLowerCase() + '-' + surface + '.junit.xml';
  const failures = cases.filter((item) => item.status !== 'passed').length;
  const junit = '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<testsuite name="NH-TEST ' + xmlEscape(stage + '/' + surface) + '" tests="' + cases.length + '" failures="' + failures + '" errors="0" skipped="0">\n' +
    cases.map((item) => '  <testcase classname="NH-TEST.' + xmlEscape(item.surface) + '" name="' + xmlEscape(item.id) + '">' +
      (item.status === 'passed' ? '' : '<failure message="scenario failed; inspect redacted shard log"/>') + '</testcase>').join('\n') +
    '\n</testsuite>\n';
  await writeFile(path.join(artifactDir, junitName), junit);
  for (const item of cases) item.artifact_paths.push(path.posix.join(path.basename(artifactDir), junitName));

  const pocketwikiSHA = gitSHA(root);
  const pocketkernelSHA = gitSHA(process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'));
  const middlewareSHA = gitSHA(process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth'));
  ensureCleanTree(root, 'PocketWiki');
  ensureCleanTree(process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'), 'PocketKernel');
  const fixtureHash = await hashFiles(fixturePaths);
  const matrixHash = await sha256File(matrixPath);
  const schemaHash = await sha256File(schemaPath);
  const report = {
    version: '0.2.0',
    stage,
    pocketwiki_sha: pocketwikiSHA,
    pocketkernel_sha: pocketkernelSHA,
    middlewareauth_sha: middlewareSHA,
    schema_sha256: schemaHash,
    fixture_sha256: fixtureHash,
    matrix_sha256: matrixHash,
    seed: 20261102,
    auth_mode: 'host_local',
    cases,
    exit_code: exitCode
  };
  const reportPath = path.join(reportDir, reportName);
  await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  console.log('NH-TEST report: ' + reportPath);
  for (const result of cases) console.log(result.id + '/' + result.surface + ': ' + result.status);
} catch (error) {
  exitCode = error.exitCode || 2;
  process.stderr.write('NH-TEST configuration failure: ' + error.message + '\n');
} finally {
  if (tempHome) await removeIsolatedHome(tempHome);
}
process.exitCode = exitCode;

function parseArgs(values) {
  const parsed = { stage: null, surface: 'all', reportDir: null };
  for (let i = 0; i < values.length; i += 1) {
    if (values[i] === '--stage') parsed.stage = values[++i];
    else if (values[i] === '--surface') parsed.surface = values[++i];
    else if (values[i] === '--report-dir') parsed.reportDir = values[++i];
    else throw configError('argumento desconhecido: ' + values[i]);
  }
  if (!/^E[0-6]$/.test(parsed.stage || '')) throw configError('use --stage E0..E6');
  if (!['service', 'web', 'macos', 'all'].includes(parsed.surface)) throw configError('use --surface service|web|macos|all');
  if (!parsed.reportDir) throw configError('--report-dir é obrigatório');
  parsed.reportDir = path.resolve(parsed.reportDir);
  return parsed;
}

function selectedPairs(stageNumber, requestedSurface, matrix) {
  const surfaces = requestedSurface === 'all' ? ['service', 'web', 'macos'] : [requestedSurface];
  return matrix.cases
    .filter((scenario) => scenario.stage <= stageNumber)
    .flatMap((scenario) => scenario.surfaces.filter((item) => surfaces.includes(item)).map((item) => ({ scenario, surface: item })));
}

async function runContract(artifactDir, tempHome, shas, deadline) {
  ensureCleanTree(root, 'PocketWiki');
  const pocketwikiSHA = gitSHA(root);
  const pocketwikiSource = await cloneGitSnapshot(root, pocketwikiSHA, path.join(tempHome, 'sources/pocketwiki'));
  const kernelRoot = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00');
  const middlewareRoot = process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth');
  if (gitSHA(kernelRoot) !== shas.pocketkernel || gitSHA(middlewareRoot) !== shas.middlewareauth) {
    throw configError('SHA de dependência diferente do pin registrado antes da lane');
  }
  const kernelSourceRoot = await exportGitSnapshot(kernelRoot, shas.pocketkernel, path.join(tempHome, 'sources/pocketkernel'));
  const middlewareSourceRoot = await exportGitSnapshot(middlewareRoot, shas.middlewareauth, path.join(tempHome, 'sources/middlewareauth'));
  const env = {
    ...isolatedEnvironment(tempHome),
    POCKETKERNEL_NH00_ROOT: kernelSourceRoot,
    MIDDLEWAREAUTH_NHTEST_ROOT: middlewareSourceRoot
  };
  const commands = [
    ['npm', ['ci', '--include=dev', '--userconfig=/dev/null', '--cache', path.join(tempHome, 'npm-cache')], pocketwikiSource],
    ['npm', ['run', 'test:harness-contracts'], pocketwikiSource],
    ['sh', ['scripts/test-nh00-acceptance.sh'], pocketwikiSource],
    ['npm', ['run', 'test:nh00-bootstrap'], pocketwikiSource],
    ['npm', ['run', 'test:nh00-chromium'], pocketwikiSource],
    ['sh', ['script/validate_pocket_interop_contract.sh'], pocketwikiSource],
    ['npm', ['run', 'test:new-harness-rig'], pocketwikiSource],
    ['sh', ['script/ci.sh'], pocketwikiSource],
    ['sh', ['script/build_nh00_matrix.sh'], kernelSourceRoot, {}],
  ];
  const artifacts = [];
  let passed = true;
  for (let index = 0; index < commands.length; index += 1) {
    const [binary, commandArgs, cwd, overrides = {}] = commands[index];
    const logName = 'contract-' + String(index + 1).padStart(2, '0') + '.log';
    const result = runWithinDeadline(binary, commandArgs, {
      cwd,
      env: { ...env, ...overrides, NH_BUILD_DIR: path.join(tempHome, 'kernel-builds') },
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024
    }, deadline, 15 * 60_000);
    const status = result.status === 0 ? 'PASS' : 'FAIL';
    const body = '$ ' + binary + ' ' + commandArgs.join(' ') + '\nexit=' + String(result.status) +
      '\n--- stdout ---\n' + (result.stdout || '') + '\n--- stderr ---\n' + (result.stderr || result.error?.message || '');
    await writeFile(path.join(artifactDir, logName), redact(body));
    artifacts.push(path.join(path.basename(artifactDir), logName));
    console.log(status + ' CONTRACT-00 ' + binary + ' ' + commandArgs.join(' ') + ' exit=' + String(result.status));
    if (result.status !== 0) passed = false;
    if (binary === 'npm' && commandArgs[0] === 'ci') {
      const restore = spawnSync('git', ['restore', '--', 'node_modules/.package-lock.json'], { cwd: pocketwikiSource, encoding: 'utf8' });
      if (restore.status !== 0) passed = false;
    }
  }
  return { ok: passed, exitCode: passed ? 0 : 1, artifacts };
}

async function runLegacy(surface, artifactDir, tempHome, deadline) {
  if (surface === 'macos') {
    const resultBundle = path.join(artifactDir, 'legacy-macos.xcresult');
    const hostScript = path.join(root, 'Tests/NewHarnessE2E/MacOSHost/run.mjs');
    const result = runWithinDeadline(process.execPath, [hostScript, '--result-bundle-path', resultBundle], {
      cwd: root,
      env: {
        ...isolatedEnvironment(tempHome),
        POCKETWIKI_XCODE_DEVELOPER_DIR: process.env.POCKETWIKI_XCODE_DEVELOPER_DIR || '',
        POCKETKERNEL_NH00_ROOT: process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'),
        MIDDLEWAREAUTH_NHTEST_ROOT: process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth')
      },
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024
    }, deadline, 15 * 60_000);
    const body = '$ node Tests/NewHarnessE2E/MacOSHost/run.mjs --result-bundle-path <report-dir>/legacy-macos.xcresult\nexit=' + String(result.status) +
      '\n--- stdout ---\n' + redact(result.stdout || '') + '\n--- stderr ---\n' + redact(result.stderr || result.error?.message || '');
    const logName = 'legacy-macos.log';
    await writeFile(path.join(artifactDir, logName), body + '\n');
    console.log('LEGACY-00/macos ' + (result.status === 0 ? 'passed' : 'failed') + ' exit=' + String(result.status));
    return {
      ok: result.status === 0,
      exitCode: result.status === 0 ? 0 : (result.status === 2 ? 2 : 1),
      configurationError: result.status === 2,
      artifacts: [
        path.join(path.basename(artifactDir), logName),
        ...(existsSync(resultBundle + '.summary.json') ? [path.join(path.basename(artifactDir), path.basename(resultBundle) + '.summary.json')] : [])
      ]
    };
  }
  const pocketwikiSHA = gitSHA(root);
  const webSource = await cloneGitSnapshot(root, pocketwikiSHA, path.join(tempHome, 'sources/pocketwiki-web'));
  const env = isolatedEnvironment(tempHome);
  const npmCache = path.join(tempHome, 'npm-cache-web');
  const install = runWithinDeadline('npm', ['ci', '--include=dev', '--userconfig=/dev/null', '--cache', npmCache], {
    cwd: webSource,
    env,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024
  }, deadline, 180_000);
  if (install.status !== 0) {
    const logName = 'legacy-web.log';
    await writeFile(path.join(artifactDir, logName), '$ npm ci --include=dev --userconfig=/dev/null --cache <isolated-cache>\nexit=' + String(install.status) +
      '\n--- stdout ---\n' + redact(install.stdout || '') + '\n--- stderr ---\n' + redact(install.stderr || install.error?.message || '') + '\n');
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [path.join(path.basename(artifactDir), logName)] };
  }
  const vendorBuild = runWithinDeadline('npm', ['run', 'build:legacy-web-assets'], {
    cwd: webSource,
    env,
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024
  }, deadline, 30_000);
  if (vendorBuild.status !== 0) {
    console.error('LEGACY-00/web local vendor build failed: ' + (vendorBuild.stderr || vendorBuild.error?.message || 'unknown error'));
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [] };
  }
  const browserPath = path.join(tempHome, 'playwright-browsers');
  const browserInstall = runWithinDeadline('npx', ['playwright', 'install', 'chromium'], {
    cwd: webSource,
    env: { ...isolatedEnvironment(tempHome), PLAYWRIGHT_BROWSERS_PATH: browserPath },
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  }, deadline);
  if (browserInstall.status !== 0) {
    console.error('LEGACY-00/web Chromium installation failed: ' + (browserInstall.stderr || browserInstall.error?.message || 'unknown error'));
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [] };
  }
  const logName = 'legacy-web.log';
  const result = runWithinDeadline(process.execPath, [path.join(webSource, 'Tests/NewHarnessE2E/legacy-web-host.mjs')], {
    cwd: webSource,
    env: {
      ...env,
      PLAYWRIGHT_BROWSERS_PATH: browserPath,
      NH_TEST_ARTIFACT_DIR: artifactDir,
      POCKETKERNEL_NH00_ROOT: process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'),
      MIDDLEWAREAUTH_NHTEST_ROOT: process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth')
    },
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  }, deadline);
  const body = '$ node Tests/NewHarnessE2E/legacy-web-host.mjs\nexit=' + String(result.status) +
    '\n--- stdout ---\n' + redact(result.stdout || '') + '\n--- stderr ---\n' + redact(result.stderr || result.error?.message || '');
  await writeFile(path.join(artifactDir, logName), body);
  console.log('LEGACY-00/web probes ' + (result.status === 0 ? 'passed' : 'incomplete') + ' exit=' + String(result.status));
  const evidence = await listArtifactPaths(artifactDir);
  return { ok: result.status === 0, exitCode: result.status === 0 ? 0 : 1, artifacts: evidence.map((name) => path.join(path.basename(artifactDir), name)) };
}

async function listArtifactPaths(directory, prefix = '') {
  const paths = [];
  for (const entry of await readdir(path.join(directory, prefix), { withFileTypes: true })) {
    const relative = path.join(prefix, entry.name);
    if (entry.isDirectory()) paths.push(...await listArtifactPaths(directory, relative));
    else if (entry.isFile()) paths.push(relative.split(path.sep).join('/'));
  }
  return paths;
}

function isolatedEnvironment(home) {
  // Keep Unix domain socket paths short for the local bootstrap integration.
  return { PATH: process.env.PATH || '/usr/bin:/bin', HOME: home, TMPDIR: '/tmp', CI: '1', POCKETWIKI_SIGN_MODE: 'adhoc' };
}
function redact(value) {
  return String(value)
    .replace(/(authorization\s*:\s*bearer\s+)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/((?:MIDDLEWARE_(?:SECRET_KEY|CLIENT_TOKEN)|POCKETWIKI_MEMORY_TOKEN|POCKETKERNEL_MIDDLEWAREAUTH_CLIENT_TOKEN)\s*[=:]\s*)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,})\b/g, '[REDACTED]');
}
async function removeIsolatedHome(home) {
  async function makeWritable(target) {
    let info;
    try { info = await lstat(target); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
    if (info.isSymbolicLink()) return;
    await chmod(target, info.isDirectory() ? 0o700 : 0o600);
    if (info.isDirectory()) {
      for (const entry of await readdir(target)) await makeWritable(path.join(target, entry));
    }
  }
  await makeWritable(home);
  await rm(home, { recursive: true, force: true });
}
function gitSHA(cwd) {
  const result = spawnSync('git', ['-C', cwd, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (result.status !== 0) throw configError('checkout git ausente: ' + cwd);
  return result.stdout.trim();
}
async function exportGitSnapshot(repository, sha, destination) {
  const status = spawnSync('git', ['-C', repository, 'status', '--porcelain=v1', '-z', '--untracked-files=all'], { encoding: 'utf8' });
  if (status.status !== 0) throw configError('não foi possível verificar o checkout pinado de ' + repository);
  const untracked = new Set();
  for (const record of status.stdout.split('\0').filter(Boolean)) {
    if (record.startsWith('?? ')) untracked.add(record.slice(3));
    else throw configError('arquivos rastreados alterados em ' + repository + '; build pinado recusado');
  }
  await cp(repository, destination, { recursive: true, filter(source) {
    const relative = path.relative(repository, source);
    if (relative === '' || relative === '.') return true;
    const segments = relative.split(path.sep);
    if (segments.includes('.git') || segments.includes('node_modules') || segments.includes('bin') || segments.includes('.build') || segments.includes('target')) return false;
    if (segments.some((segment) => segment === '.env' || segment.startsWith('.env.'))) return false;
    if ([...untracked].some((entry) => relative === entry || relative.startsWith(entry + path.sep))) return false;
    return true;
  } });
  return destination;
}
async function cloneGitSnapshot(repository, sha, destination) {
  await mkdir(path.dirname(destination), { recursive: true });
  const clone = spawnSync('git', ['clone', '--shared', '--no-checkout', repository, destination], { encoding: 'utf8', timeout: 30_000 });
  if (clone.status !== 0) throw configError('não foi possível criar checkout isolado do PocketWiki: ' + (clone.stderr || clone.error?.message || 'git clone falhou'));
  const checkout = spawnSync('git', ['-C', destination, 'checkout', '--detach', sha], { encoding: 'utf8', timeout: 30_000 });
  if (checkout.status !== 0 || gitSHA(destination) !== sha) throw configError('checkout isolado do PocketWiki divergiu do SHA executado');
  return destination;
}
function ensureCleanTree(cwd, label) {
  const result = spawnSync('git', ['-C', cwd, 'status', '--porcelain=v1', '--untracked-files=no'], { encoding: 'utf8' });
  if (result.status !== 0 || result.stdout.trim()) throw configError(label + ' tracked files are dirty; refusing to emit a misleading SHA report');
}
function parsePinnedSHAs(text) {
  const pocketkernel = text.match(/PocketKernel: \x60([a-f0-9]{40})\x60/);
  const middleware = text.match(/MiddlewareAuth: \x60([a-f0-9]{40})\x60/);
  if (!pocketkernel || !middleware) throw configError('registro de bases NH-TEST incompleto');
  return { pocketkernel: pocketkernel[1], middlewareauth: middleware[1] };
}
async function hashFiles(files) {
  const hash = createHash('sha256');
  for (const relative of files) {
    hash.update(relative + '\0');
    hash.update(await readFile(path.join(root, relative)));
    hash.update('\n');
  }
  return hash.digest('hex');
}
async function sha256File(file) { return createHash('sha256').update(await readFile(file)).digest('hex'); }
function configError(message) { return Object.assign(new Error(message), { exitCode: 2 }); }
function runWithinDeadline(binary, args, options, deadline, cap = 180_000) {
  const timeLeft = Math.min(cap, deadline - Date.now());
  if (timeLeft <= 0) return { status: null, error: new Error('global 180s scenario deadline exceeded') };
  return spawnSync(binary, args, { ...options, timeout: timeLeft });
}
function xmlEscape(value) { return String(value).replace(/[<>&"']/g, (character) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[character]); }
