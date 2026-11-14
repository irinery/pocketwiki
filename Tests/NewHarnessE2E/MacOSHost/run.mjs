import { runtimeScreenshotPayload, sanitizeRuntimeScreenshot } from './runtime-screenshot.mjs';
import { assertRuntimeProof, runtimeProofExitCode } from './runtime-proof.mjs';
import { createHelperLauncher, cleanupManagedHelpers } from './managed-helpers.mjs';
import { helperPaths } from './supervisor.mjs';
import { assertTrackedFlags, exportGitSnapshot } from '../git-snapshot.mjs';
import { createServer } from 'node:http';
import { runAndCapture } from '../deadline-process.mjs';
import { runWithinDeadline, requireProcessListing } from '../deadline-sync.mjs';
import { createServer as createNetServer } from 'node:net';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const project = path.join(root, 'Tests/NewHarnessE2E/MacOSHost/PocketWikiMacNHTestHost.xcodeproj');
const resultBundle = parseFlag(process.argv.slice(2), '--result-bundle-path');
const logPath = resultBundle.replace(/\.xcresult$/, '') + '.log';
const runtimeHook = process.env.NH_RUNTIME_LEGACY_UI === '1';
const proofOutput = resultBundle + '.runtime-proof.json';
const screenshotOutput = resultBundle + '.runtime-fallback.png';
await rm(proofOutput, { force: true });
await rm(screenshotOutput, { force: true });
try { requireProcessListing(); } catch (error) { reportConfigFailure(error.message); }
const explicitDeveloperDir = process.env.POCKETWIKI_XCODE_DEVELOPER_DIR || process.env.DEVELOPER_DIR;
const selected = explicitDeveloperDir
  ? { status: 0, stdout: explicitDeveloperDir }
  : spawnSync('xcode-select', ['-p'], { encoding: 'utf8' });
const developerDir = selected.stdout?.trim();

if (selected.status !== 0 || !developerDir || developerDir.includes('/CommandLineTools')) {
  reportConfigFailure('Xcode completo com XCTest não está disponível. Instale Xcode ou defina POCKETWIKI_XCODE_DEVELOPER_DIR; a seleção global não foi alterada.');
}
const xcodebuild = path.join(developerDir, 'usr', 'bin', 'xcodebuild');
if (!existsSync(xcodebuild)) reportConfigFailure('xcodebuild não existe em ' + xcodebuild);
await mkdir(path.dirname(resultBundle), { recursive: true });

const kernelRoot = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00');
const middlewareRoot = process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth');
const tempHome = await mkdtemp(path.join(os.tmpdir(), 'pocketwiki-legacy00-macos-'));
const supervised = Boolean(process.env.NH_MAC_HELPER_DIR);
const helpers = helperPaths(process.env.NH_MAC_HELPER_DIR || tempHome);
const [{ binary: kernelBinary, launcher: kernelLauncher }, { binary: middlewareBinary, launcher: middlewareLauncher }] = helpers;
const providerRequests = [];
const provider = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString('utf8');
  if (request.method === 'GET' && request.url === '/v1/models') {
    return sendJSON(response, 200, { data: [{ id: 'nh-test-model', object: 'model', owned_by: 'nh-test' }] });
  }
  if (request.method === 'POST' && request.url === '/v1/chat/completions') {
    const payload = safeJSON(body) || {};
    const promptContainsWikiMarker = JSON.stringify(payload.messages || []).includes('nh-test-marker-2026');
    const authorized = request.headers.authorization === 'Bearer nh-test-provider-key';
    providerRequests.push({ path: request.url, prompt_contains_wiki_marker: promptContainsWikiMarker, authorized, model: payload.model || null });
    if (!authorized || payload.model !== 'nh-test-model' || !promptContainsWikiMarker) {
      return sendJSON(response, 422, { error: { message: 'NH-TEST provider fixture requires auth, model and PocketWiki evidence marker' } });
    }
    return sendJSON(response, 200, {
      id: 'chatcmpl-nh-test-fixture',
      object: 'chat.completion',
      created: 1793550000,
      model: 'nh-test-model',
      choices: [{ index: 0, message: { role: 'assistant', content: 'Evidência local encontrada: nh-test-marker-2026.' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 32, completion_tokens: 8, total_tokens: 40 }
    });
  }
  sendJSON(response, 404, { error: { message: 'not found' } });
});
let output = '';
let status = 2;
let runtimeProofVerified = false;
let runtimeScreenshot;
const proofNonce = process.env.NH_RUNTIME_PROOF_NONCE || '';
const proofSHA = process.env.NH_RUNTIME_PROOF_SHA || '';
const proofMarker = path.join(tempHome, 'runtime-xctest-proof');
try {
  if (!supervised) {
    await createHelperLauncher(kernelLauncher, kernelBinary, helpers[0].ledger);
    await createHelperLauncher(middlewareLauncher, middlewareBinary, helpers[1].ledger);
  }
  if (runtimeHook) {
    if (!/^[a-f0-9]{32,128}$/.test(proofNonce)) throw Object.assign(new Error('runtime proof nonce inválido'), { exitCode: 2 });
    assertWikiProofIdentity(root, proofSHA);
    for (const file of ['Sources/PocketWikiMac/Views/Harness/Runtime/RuntimePanel.swift', 'Sources/PocketWikiMac/Views/Harness/Runtime/RuntimeUISession.swift']) {
      if (!existsSync(path.join(root, file))) throw Object.assign(new Error('fontes do slot runtime indisponíveis: ' + file), { exitCode: 2 });
    }
  }
  const pinned = await readFile(path.join(root, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8');
  const kernelSHA = pinned.match(/PocketKernel: \x60([a-f0-9]{40})\x60/)?.[1];
  const middlewareSHA = pinned.match(/MiddlewareAuth: \x60([a-f0-9]{40})\x60/)?.[1];
  if (!kernelSHA || !middlewareSHA || gitSHA(kernelRoot) !== kernelSHA || gitSHA(middlewareRoot) !== middlewareSHA) {
    throw new Error('helper checkout diverge dos SHAs imutáveis registrados');
  }
  const kernelSource = path.join(tempHome, 'sources', 'pocketkernel');
  const middlewareSource = path.join(tempHome, 'sources', 'middlewareauth');
  await exportGitSnapshot(kernelRoot, kernelSHA, kernelSource);
  await exportGitSnapshot(middlewareRoot, middlewareSHA, middlewareSource);
  const built = await buildHelpers({ kernelRoot: kernelSource, middlewareRoot: middlewareSource, kernelBinary, middlewareBinary, tempHome });
  if (built.status !== 0) {
    output += built.output;
    throw new Error('não foi possível compilar PocketKernel/MiddlewareAuth reais no diretório temporário');
  }
  await new Promise((resolve, reject) => {
    provider.once('error', reject);
    provider.listen(0, '127.0.0.1', resolve);
  });
  const address = provider.address();
  const providerURL = `http://127.0.0.1:${address.port}`;
  const middlewareURL = await availableLoopbackURL();
  const kernelURL = await availableLoopbackURL();
  const pocketWikiPort = Number(new URL(await availableLoopbackURL()).port);
  const env = {
    ...process.env,
    HOME: tempHome,
    CFFIXED_USER_HOME: tempHome,
    TMPDIR: tempHome,
    DEVELOPER_DIR: developerDir,
    NH_TEST_FIXTURE_PROVIDER_URL: providerURL,
    NH_TEST_MIDDLEWARE_URL: middlewareURL,
    NH_TEST_KERNEL_URL: kernelURL,
    ...(runtimeHook ? { NH_RUNTIME_LEGACY_UI: '1', NH_RUNTIME_SCHEMA_PATH: path.join(root, 'src/harness/contracts/harness-v1.schema.json'), NH_RUNTIME_PROOF_PATH: proofMarker, NH_RUNTIME_PROOF_NONCE: proofNonce } : {}),
    NH_TEST_POCKETWIKI_PORT: String(pocketWikiPort),
    POCKETWIKI_POCKETKERNEL_BINARY: kernelLauncher,
    POCKETWIKI_MIDDLEWARE_AUTH_BINARY: middlewareLauncher,
    POCKETWIKI_NODE_BINARY: process.execPath,
    MIDDLEWAREAUTH_BASE_URL: middlewareURL,
    POCKETKERNEL_MIDDLEWAREAUTH_BASE_URL: middlewareURL,
    LMSTUDIO_BASE_URL: providerURL,
    MCP_LMSTUDIO_MODEL: 'nh-test-model'
  };
  const destinations = await runWithinDeadline(xcodebuild, ['-showdestinations', '-project', project, '-scheme', 'PocketWikiMacNHTestHost'], {
    cwd: root,
    env,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  }, Date.now() + 60_000);
  output += '--- xcodebuild -showdestinations ---\n' + (destinations.stdout || '') + (destinations.stderr || '');
  if (destinations.status !== 0) throw new Error('xcodebuild não conseguiu listar os destinos macOS disponíveis');
  const macDestination = [...(destinations.stdout || '').matchAll(/\{[^{}]*platform:macOS, arch:([^,}]+), id:([^,}]+), name:([^}]+)\}/g)]
    .find((match) => match[3].trim() === 'My Mac');
  if (!macDestination) throw new Error('Xcode não anunciou o destino My Mac arm64 para este scheme');
  const args = [
    'test-without-building', '-project', project,
    '-scheme', 'PocketWikiMacNHTestHost',
    '-destination', 'id=' + macDestination[2].trim(),
    '-disableAutomaticPackageResolution',
    '-derivedDataPath', path.join(tempHome, 'derived-data'),
    '-clonedSourcePackagesDirPath', path.join(tempHome, 'swift-packages'),
    '-resultBundlePath', resultBundle,
    `NH_TEST_FIXTURE_PROVIDER_URL=${providerURL}`,
    `NH_TEST_MIDDLEWARE_URL=${middlewareURL}`,
    `NH_TEST_KERNEL_URL=${kernelURL}`,
    ...(runtimeHook ? ['OTHER_SWIFT_FLAGS=$(inherited) -D NH_RUNTIME_TEST_HOOK', 'NH_RUNTIME_LEGACY_UI=1', `NH_RUNTIME_SCHEMA_PATH=${path.join(root, 'src/harness/contracts/harness-v1.schema.json')}`, `NH_RUNTIME_PROOF_PATH=${proofMarker}`, `NH_RUNTIME_PROOF_NONCE=${proofNonce}`] : ['EXCLUDED_SOURCE_FILE_NAMES=RuntimePanel.swift RuntimeUISession.swift RuntimeProjection.swift RuntimeTransport.swift']),
    `NH_TEST_POCKETWIKI_PORT=${pocketWikiPort}`,
    `POCKETWIKI_POCKETKERNEL_BINARY=${kernelLauncher}`,
    `POCKETWIKI_MIDDLEWARE_AUTH_BINARY=${middlewareLauncher}`,
    `POCKETWIKI_NODE_BINARY=${process.execPath}`
  ];
  const buildArgs = [...args];
  buildArgs[0] = 'build-for-testing';
  const resultIndex = buildArgs.indexOf('-resultBundlePath');
  buildArgs.splice(resultIndex, 2);
  const build = await runAndCapture(xcodebuild, buildArgs, root, env, 12 * 60_000);
  output += '--- build-for-testing ---\n' + build.output;
  if (build.status !== 0) throw new Error('xcodebuild build-for-testing falhou ou excedeu o prazo');
  const run = await runAndCapture(xcodebuild, args, root, env, 180_000);
  output += run.output;
  status = run.status;
  if (status === 0 && !providerRequests.some((item) => item.prompt_contains_wiki_marker && item.authorized && item.model === 'nh-test-model')) {
    status = 1;
    output += '\nFAIL: XCTest terminou sem requisição fixture autenticada contendo evidência da wiki.\n';
  }
  output += '\nProvider fixture requests: ' + JSON.stringify(providerRequests) + '\n';
  if (existsSync(resultBundle)) {
    const summary = spawnSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', resultBundle, '--format', 'json'], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    try {
      if (summary.status !== 0) throw new Error(summary.stderr || summary.error?.message || 'xcresulttool falhou');
      const safeSummary = redactSummary(summary.stdout);
      const parsedSummary = JSON.parse(safeSummary);
      if (runtimeHook && status === 0) {
        const marker = await readFile(proofMarker, 'utf8').catch(() => '');
        assertRuntimeProof({ marker, nonce: proofNonce, summary: parsedSummary });
        runtimeScreenshot = await extractRuntimeScreenshot(resultBundle, tempHome, developerDir);
        runtimeProofVerified = true;
      }
      await writeFile(resultBundle + '.summary.json', safeSummary + '\n', { mode: 0o600 });
    } catch (error) {
      status = status === 0 ? 1 : status;
      output += '\nFAIL: não foi possível extrair o resumo sanitizado do xcresult. ' + error.message + '\n';
    } finally {
      await makeWritable(resultBundle);
      await rm(resultBundle, { recursive: true, force: true });
    }
  }
} catch (error) {
  output += '\nHost failure: ' + error.message + '\n';
  status = error.exitCode || (error.message.startsWith('não foi possível compilar') ? 2 : 1);
} finally {
  try { await cleanupManagedHelpers(helpers); } catch (error) { status = 1; output += '\nFAIL: helper cleanup: ' + error.message + '\n'; }
  if (provider.listening) await new Promise((resolve) => provider.close(resolve));
  if (runtimeHook && status === 0) {
    try { assertWikiProofIdentity(root, proofSHA); } catch (error) { status = 1; output += '\nFAIL: identidade do checkout mudou durante teste.\n'; }
  }
  const checkedStatus = runtimeProofExitCode(status, runtimeHook, runtimeProofVerified);
  if (checkedStatus !== status) output += '\nFAIL: prova runtime ou xcresult ausente.\n';
  status = checkedStatus;
  if (runtimeHook && status === 0 && runtimeProofVerified) {
    await writeFile(screenshotOutput, runtimeScreenshot, { mode: 0o600 });
    await writeFile(proofOutput, JSON.stringify({ nonce: proofNonce, pocketwiki_sha: proofSHA, runtime_fallback_verified: true, legacy_capability_status: 404, skipped_tests: 0 }, null, 2) + '\n', { mode: 0o600 });
  } else { await rm(proofOutput, { force: true }); await rm(screenshotOutput, { force: true }); }
  output = redactSummary(output);
  await writeFile(logPath, output, 'utf8');
  process.stdout.write(output);
  await makeWritable(tempHome);
  await rm(tempHome, { recursive: true, force: true });
}
process.exit(status);

function assertWikiProofIdentity(wiki, expectedSHA) {
  if (!/^[a-f0-9]{40}$/.test(expectedSHA) || gitSHA(wiki) !== expectedSHA) throw Object.assign(new Error('runtime proof SHA inválido'), { exitCode: 2 });
  assertTrackedFlags(wiki);
  const status = spawnSync('git', ['-C', wiki, 'status', '--porcelain=v1', '--untracked-files=no'], { encoding: 'utf8' });
  if (status.status !== 0 || status.stdout.trim()) throw Object.assign(new Error('PocketWiki checkout alterado'), { exitCode: 2 });
}

async function extractRuntimeScreenshot(bundle, tempHome, developerDir) {
  const toolEnv = { ...process.env, DEVELOPER_DIR: developerDir };
  const activity = spawnSync('xcrun', ['xcresulttool', 'get', 'test-results', 'activities', '--test-id', 'Legacy00UITests/testLegacy00UsesRealAppBridgeAndRestoresAfterRestart()', '--path', bundle, '--compact'], { env: toolEnv, encoding: 'utf8', timeout: 30_000, maxBuffer: 8 * 1024 * 1024 });
  if (activity.status !== 0) throw new Error('falha ao localizar screenshot do slot fixture');
  const payload = runtimeScreenshotPayload(JSON.parse(activity.stdout));
  const file = path.join(tempHome, 'runtime-fallback-selected.png');
  const extracted = spawnSync('xcrun', ['xcresulttool', 'export', 'object', '--legacy', '--type', 'file', '--id', payload, '--path', bundle, '--output-path', file], { env: toolEnv, encoding: 'utf8', timeout: 30_000, maxBuffer: 1024 * 1024 });
  if (extracted.status !== 0) throw new Error('falha ao extrair screenshot do slot fixture');
  const info = await lstat(file);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('screenshot do slot inválido');
  return sanitizeRuntimeScreenshot(await readFile(file));
}

async function buildHelpers({ kernelRoot, middlewareRoot, kernelBinary, middlewareBinary, tempHome }) {
  const common = { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 };
  const env = { ...process.env, HOME: tempHome, CGO_ENABLED: '0', GOCACHE: path.join(tempHome, 'go-cache'), GOPATH: path.join(tempHome, 'go') };
  const deadline = Date.now() + 12 * 60_000;
  const kernel = await runWithinDeadline('go', ['build', '-mod=readonly', '-o', kernelBinary, './cmd/pocketkernel'], { ...common, cwd: kernelRoot, env }, deadline, 12 * 60_000);
  if (kernel.status !== 0) return { status: kernel.status ?? 2, output: '--- go build PocketKernel ---\n' + (kernel.stdout || '') + (kernel.stderr || kernel.error?.message || '') };
  const middleware = await runWithinDeadline('go', ['build', '-mod=readonly', '-o', middlewareBinary, './cmd/middleware-codex-oauth'], { ...common, cwd: middlewareRoot, env }, deadline, 12 * 60_000);
  if (middleware.status !== 0) return { status: middleware.status ?? 2, output: '--- go build MiddlewareAuth ---\n' + (middleware.stdout || '') + (middleware.stderr || middleware.error?.message || '') };
  return { status: 0, output: '' };
}

function gitSHA(repository) {
  const result = spawnSync('git', ['-C', repository, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('git checkout indisponível: ' + repository);
  return result.stdout.trim();
}



async function makeWritable(target) {
  let info;
  try { info = await lstat(target); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (info.isSymbolicLink()) return;
  await chmod(target, info.isDirectory() ? 0o700 : 0o600);
  if (info.isDirectory()) for (const entry of await readdir(target)) await makeWritable(path.join(target, entry));
}

async function availableLoopbackURL() {
  const server = createNetServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return `http://127.0.0.1:${port}`;
}

function sendJSON(response, statusCode, value) {
  response.writeHead(statusCode, { 'content-type': 'application/json', 'connection': 'close' });
  response.end(JSON.stringify(value));
}
function redactSummary(value) {
  return String(value)
    .replace(/nh-test-provider-key/g, '[REDACTED]')
    .replace(/dev-middleware-token-for-tests-only/g, '[REDACTED]')
    .replace(/nh-test-memory-token-[A-Za-z0-9-]*/g, '[REDACTED]')
    .replace(/(authorization\s*:\s*bearer\s+)[^\s"']+/gi, '$1[REDACTED]');
}
function safeJSON(value) { try { return JSON.parse(value); } catch { return null; } }
function parseFlag(args, flag) {
  const index = args.indexOf(flag);
  if (index < 0 || !args[index + 1]) {
    reportConfigFailure(`Uso: node Tests/NewHarnessE2E/MacOSHost/run.mjs ${flag} <diretório.xcresult>`);
  }
  return path.resolve(args[index + 1]);
}
function reportConfigFailure(message) {
  process.stderr.write('NH-TEST macOS configuration failure: ' + message + '\n');
  process.exit(2);
}
