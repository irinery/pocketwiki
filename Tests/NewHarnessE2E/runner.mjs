import { isolatedEnvironment } from './isolated-environment.mjs';
import { DEFAULT_FIXTURE_SEED } from '../Harness/runtime/fixture-identities.mjs';
import { superviseMacHost } from './MacOSHost/supervisor.mjs';
import { exportGitSnapshot } from './git-snapshot.mjs';
import { existsSync } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { runWithinDeadline, requireProcessListing } from './deadline-sync.mjs';
import { targetIdentity, assertSameIdentity } from './gate-aggregator.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const matrixPath = path.join(root, 'docs/rfcs/new-harness/matriz-verificacao.json');
const args = parseArgs(process.argv.slice(2));
const stage = args.stage;
const surface = args.surface;
const reportDir = args.reportDir;
const stageNumber = Number(stage.slice(1));
const reportName = stage.toLowerCase() + '-' + surface + '.json';
let exitCode = 0;
let tempHome;

try {
  // Invalidate previous output before any preflight can fail.
  await rm(path.join(reportDir, reportName), { force: true });
  await rm(path.join(reportDir, stage.toLowerCase() + '-' + surface), { recursive: true, force: true });
  requireProcessListing();
  const kernelRoot = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00');
  const middlewareRoot = process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth');
  const targetSHA = gitSHA(root);
  const identity = await targetIdentity(root, kernelRoot, middlewareRoot, targetSHA, stage);
  const baseSHAs = parsePinnedSHAs(await readFile(path.join(root, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8'));
  if (identity.pocketkernel_sha !== baseSHAs.pocketkernel || identity.middlewareauth_sha !== baseSHAs.middlewareauth) throw configError('SHA de dependência diferente do pin ativo');
  const matrix = JSON.parse(await readFile(matrixPath, 'utf8'));
  const selected = selectedPairs(stageNumber, surface, matrix);
  const unsupported = selected.filter(({ scenario }) => !['CONTRACT-00', 'LEGACY-00', 'SERVICE-0002', 'UI-0002'].includes(scenario.id));
  if (unsupported.length) throw configError('faltam dependências/handlers dos cenários: ' + unsupported.map(({ scenario }) => scenario.id).join(', '));

  await mkdir(reportDir, { recursive: true });
  tempHome = await mkdtemp(path.join(os.tmpdir(), 'nh-test-runtime-'));
  const artifactDir = path.join(reportDir, stage.toLowerCase() + '-' + surface);
  await mkdir(artifactDir, { recursive: true });

  const cases = [];
  for (const pair of selected) {
    // macOS launcher enforces 180s on XCTest after its build preparation.
    const scenarioTimeout = pair.surface === 'macos' ? 30 * 60_000 : 180_000;
    const deadline = Date.now() + scenarioTimeout;
    const id = pair.scenario.id;
    const result = id === 'CONTRACT-00'
      ? await runContract(artifactDir, tempHome, baseSHAs, deadline, targetSHA)
      : id === 'LEGACY-00' ? await runLegacy(pair.surface, artifactDir, tempHome, deadline, targetSHA)
      : id === 'SERVICE-0002' ? await runRuntimeService(artifactDir, tempHome, targetSHA, baseSHAs)
      : await runRuntimeUI(pair.surface, artifactDir, tempHome, targetSHA);
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

  const finalIdentity = await targetIdentity(root, kernelRoot, middlewareRoot, targetSHA, stage);
  assertSameIdentity(identity, finalIdentity);
  const report = {
    version: '0.2.0',
    stage,
    ...identity,
    seed: DEFAULT_FIXTURE_SEED,
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

async function runContract(artifactDir, tempHome, shas, deadline, targetSHA) {
  ensureCleanTree(root, 'PocketWiki');
  const pocketwikiSource = await cloneGitSnapshot(root, targetSHA, path.join(tempHome, 'sources/pocketwiki'));
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
  let regressionDeadline;
  for (let index = 0; index < commands.length; index += 1) {
    const [binary, commandArgs, cwd, overrides = {}] = commands[index];
    const logName = 'contract-' + String(index + 1).padStart(2, '0') + '.log';
    // Full CI and cross-build are mandatory gate checks with a separate bounded budget.
    if (index === 7) regressionDeadline = Date.now() + 15 * 60_000;
    const commandDeadline = index === 0 ? Date.now() + 15 * 60_000 : (index >= 7 ? regressionDeadline : deadline);
    const result = await runWithinDeadline(binary, commandArgs, {
      cwd,
      env: { ...env, ...overrides, NH_BUILD_DIR: path.join(tempHome, 'kernel-builds') },
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024
    }, commandDeadline, 15 * 60_000);
    const status = result.status === 0 ? 'PASS' : 'FAIL';
    const body = '$ ' + binary + ' ' + commandArgs.join(' ') + '\nexit=' + String(result.status) +
      '\n--- stdout ---\n' + (result.stdout || '') + '\n--- stderr ---\n' + (result.stderr || result.error?.message || '');
    await writeFile(path.join(artifactDir, logName), redact(body));
    artifacts.push(path.join(path.basename(artifactDir), logName));
    console.log(status + ' CONTRACT-00 ' + binary + ' ' + commandArgs.join(' ') + ' exit=' + String(result.status));
    if (result.status !== 0) passed = false;
    if (binary === 'npm' && commandArgs[0] === 'ci') {
      // Dependency installation is preparation, not part of CONTRACT-00 execution.
      deadline = Date.now() + 180_000;
      const restore = spawnSync('git', ['restore', '--', 'node_modules/.package-lock.json'], { cwd: pocketwikiSource, encoding: 'utf8' });
      if (restore.status !== 0) passed = false;
    }
  }
  return { ok: passed, exitCode: passed ? 0 : 1, artifacts };
}

async function runRuntimeService(artifactDir, tempHome, targetSHA, shas) {
  const source = await cloneGitSnapshot(root, targetSHA, path.join(tempHome, 'sources/pocketwiki-runtime'));
  const kernelRoot = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00');
  const kernelSource = await exportGitSnapshot(kernelRoot, shas.pocketkernel, path.join(tempHome, 'sources/pocketkernel-runtime'));
  const kernel = path.join(tempHome, 'runtime-kernel');
  const swift = path.join(tempHome, 'runtime-swift');
  const env = isolatedEnvironment(tempHome);
  const logName = 'service-0002.log';
  const artifacts = [path.posix.join(path.basename(artifactDir), logName)];
  const evidence = path.join(artifactDir, 'service-0002-receipts-events.json');
  let log = '';
  const commands = [
    ['go', ['build', '-trimpath', '-o', kernel, './cmd/pocketkernel'], kernelSource],
    ['swiftc', ['-swift-version', '6', 'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift', 'Sources/PocketWikiMac/Models/Harness/HarnessV1.swift', 'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeTransport.swift', 'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeProjection.swift', 'Tests/Harness/runtime/SwiftKernelIntegration.swift', '-o', swift], source],
    [process.execPath, ['Tests/Harness/runtime/kernel-integration.mjs'], source]
  ];
  for (let i = 0; i < commands.length; i++) {
    const [binary, argv, cwd] = commands[i];
    const timeout = i < 2 ? 15 * 60_000 : 180_000;
    const result = await runWithinDeadline(binary, argv, { cwd, env: { ...env, RUNTIME_KERNEL_BINARY: kernel, RUNTIME_SWIFT_BINARY: swift, RUNTIME_EVIDENCE_PATH: evidence, RUNTIME_FIXTURE_SEED: String(DEFAULT_FIXTURE_SEED) }, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }, Date.now() + timeout, timeout);
    log += '$ ' + path.basename(binary) + ' ' + argv.join(' ') + '\nexit=' + result.status + '\n' + (result.stdout || '') + '\n' + (result.stderr || result.error?.message || '') + '\n';
    if (result.status !== 0) {
      await writeFile(path.join(artifactDir, logName), redact(log));
      return { ok: false, exitCode: i < 2 ? 2 : 1, configurationError: i < 2, artifacts };
    }
  }
  await writeFile(path.join(artifactDir, logName), redact(log));
  if (!existsSync(evidence)) return { ok: false, exitCode: 1, artifacts };
  artifacts.push(path.posix.join(path.basename(artifactDir), path.basename(evidence)));
  return { ok: true, artifacts };
}

async function runRuntimeUI(surface, artifactDir, tempHome, targetSHA) {
  const source = await cloneGitSnapshot(root, targetSHA, path.join(tempHome, 'sources/pocketwiki-ui-' + surface));
  const host = path.join(source, 'Tests/HarnessUI/runtime/run-host.mjs');
  if (!existsSync(host)) return { ok: false, exitCode: 2, configurationError: true, artifacts: [] };
  const output = path.join(artifactDir, 'ui-0002-' + surface);
  await mkdir(output, { recursive: true });
  const launch = surface === 'macos' ? superviseMacHost : runWithinDeadline;
  const timeout = surface === 'macos' ? 60 * 60_000 : 20 * 60_000;
  const result = await launch(process.execPath, [host, '--surface', surface, '--report-dir', output], {
    cwd: source, env: { ...isolatedEnvironment(tempHome), POCKETKERNEL_NH00_ROOT: process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'), MIDDLEWAREAUTH_NHTEST_ROOT: process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth') }, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024
  }, Date.now() + timeout, timeout);
  const log = 'ui-0002-' + surface + '.log';
  await writeFile(path.join(artifactDir, log), redact((result.stdout || '') + '\n' + (result.stderr || result.error?.message || '')));
  const evidence = await listArtifactPaths(output);
  // The host contract requires a machine-readable manifest proving all four UI cases.
  let manifest;
  try { manifest = JSON.parse(await readFile(path.join(output, 'result.json'), 'utf8')); } catch {}
  const required = ['02-01', '02-02', '02-03', '02-04'];
  const valid = manifest && Array.isArray(manifest.cases) && manifest.cases.length === 4 && required.every(id => manifest.cases.some(c => c.id === id && ['passed', 'failed'].includes(c.status))) && evidence.some(name => name !== 'result.json');
  // The current host exercises B=9 against the Kernel; unit tests at B=10 are
  // not the integrated UI case required by RFC 0002. Keep this closed even
  // if a stale or incorrect host claims success.
  const passed = false;
  return { ok: result.status === 0 && passed, exitCode: result.status === 2 || !valid ? 2 : 1, configurationError: result.status === 2 || !valid, artifacts: [path.posix.join(path.basename(artifactDir), log), ...evidence.map(name => path.posix.join(path.basename(artifactDir), 'ui-0002-' + surface, name))] };
}

async function runLegacy(surface, artifactDir, tempHome, deadline, targetSHA) {
  if (surface === 'macos') {
    // Keep the raw bundle outside the upload tree, including on timeout or crash.
    const resultBundle = path.join(tempHome, 'legacy-macos.xcresult');
    const artifactBase = path.join(artifactDir, 'legacy-macos.xcresult');
    for (const suffix of ['.summary.json', '.legacy-fixture-failure.png']) await rm(artifactBase + suffix, { force: true });
    const macSource = await cloneGitSnapshot(root, targetSHA, path.join(tempHome, 'sources/pocketwiki-macos'));
    const hostScript = path.join(macSource, 'Tests/NewHarnessE2E/MacOSHost/run.mjs');
    const result = await superviseMacHost(process.execPath, [hostScript, '--result-bundle-path', resultBundle], {
      cwd: macSource,
      env: {
        ...isolatedEnvironment(tempHome),
        POCKETWIKI_XCODE_DEVELOPER_DIR: process.env.POCKETWIKI_XCODE_DEVELOPER_DIR || '',
        POCKETKERNEL_NH00_ROOT: process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00'),
        MIDDLEWAREAUTH_NHTEST_ROOT: process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth')
      },
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024
    }, deadline, 30 * 60_000);
    for (const suffix of ['.summary.json', ...(result.status !== 0 ? ['.legacy-fixture-failure.png'] : [])]) {
      if (existsSync(resultBundle + suffix)) {
        try { await copyFile(resultBundle + suffix, artifactBase + suffix); }
        catch { await rm(artifactBase + suffix, { force: true }).catch(() => {}); }
      }
    }
    const screenshotAvailable = existsSync(artifactBase + '.legacy-fixture-failure.png');
    const body = '$ node Tests/NewHarnessE2E/MacOSHost/run.mjs --result-bundle-path <temporary-dir>/legacy-macos.xcresult\nexit=' + String(result.status) +
      '\n--- stdout ---\n' + redact(result.stdout || '') + '\n--- stderr ---\n' + redact(result.stderr || result.error?.message || '') +
      (result.status !== 0 ? '\nScreenshot da fixture: ' + (screenshotAvailable ? 'disponível' : 'indisponível') + '.\n' : '');
    const logName = 'legacy-macos.log';
    await writeFile(path.join(artifactDir, logName), body + '\n');
    console.log('LEGACY-00/macos ' + (result.status === 0 ? 'passed' : 'failed') + ' exit=' + String(result.status));
    return {
      ok: result.status === 0,
      exitCode: result.status === 0 ? 0 : (result.status === 2 ? 2 : 1),
      configurationError: result.status === 2,
      artifacts: [
        path.join(path.basename(artifactDir), logName),
        ...(result.status !== 0 && screenshotAvailable ? [path.join(path.basename(artifactDir), path.basename(artifactBase) + '.legacy-fixture-failure.png')] : []),
        ...(existsSync(artifactBase + '.summary.json') ? [path.join(path.basename(artifactDir), path.basename(artifactBase) + '.summary.json')] : [])
      ]
    };
  }
  const webSource = await cloneGitSnapshot(root, targetSHA, path.join(tempHome, 'sources/pocketwiki-web'));
  const env = isolatedEnvironment(tempHome);
  const npmCache = path.join(tempHome, 'npm-cache-web');
  const preparationDeadline = Date.now() + 15 * 60_000;
  const install = await runWithinDeadline('npm', ['ci', '--include=dev', '--userconfig=/dev/null', '--cache', npmCache], {
    cwd: webSource,
    env,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024
  }, preparationDeadline, 15 * 60_000);
  if (install.status !== 0) {
    const logName = 'legacy-web.log';
    await writeFile(path.join(artifactDir, logName), '$ npm ci --include=dev --userconfig=/dev/null --cache <isolated-cache>\nexit=' + String(install.status) +
      '\n--- stdout ---\n' + redact(install.stdout || '') + '\n--- stderr ---\n' + redact(install.stderr || install.error?.message || '') + '\n');
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [path.join(path.basename(artifactDir), logName)] };
  }
  const vendorBuild = await runWithinDeadline('npm', ['run', 'build:legacy-web-assets'], {
    cwd: webSource,
    env,
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024
  }, preparationDeadline, 15 * 60_000);
  if (vendorBuild.status !== 0) {
    console.error('LEGACY-00/web local vendor build failed: ' + (vendorBuild.stderr || vendorBuild.error?.message || 'unknown error'));
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [] };
  }
  const browserPath = path.join(tempHome, 'playwright-browsers');
  const browserInstall = await runWithinDeadline('npx', ['playwright', 'install', 'chromium'], {
    cwd: webSource,
    env: { ...isolatedEnvironment(tempHome), PLAYWRIGHT_BROWSERS_PATH: browserPath },
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  }, preparationDeadline, 15 * 60_000);
  if (browserInstall.status !== 0) {
    console.error('LEGACY-00/web Chromium installation failed: ' + (browserInstall.stderr || browserInstall.error?.message || 'unknown error'));
    return { ok: false, exitCode: 2, configurationError: true, artifacts: [] };
  }
  deadline = Date.now() + 180_000;
  const logName = 'legacy-web.log';
  const result = await runWithinDeadline(process.execPath, [path.join(webSource, 'Tests/NewHarnessE2E/legacy-web-host.mjs')], {
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
function configError(message) { return Object.assign(new Error(message), { exitCode: 2 }); }
function xmlEscape(value) { return String(value).replace(/[<>&"']/g, (character) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[character]); }
