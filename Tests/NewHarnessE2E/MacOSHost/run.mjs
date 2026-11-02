import { createServer } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const project = path.join(root, 'Tests/NewHarnessE2E/MacOSHost/PocketWikiMacNHTestHost.xcodeproj');
const resultBundle = parseFlag(process.argv.slice(2), '--result-bundle-path');
const logPath = resultBundle.replace(/\.xcresult$/, '') + '.log';
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
const kernelBinary = path.join(tempHome, 'pocketkernel');
const middlewareBinary = path.join(tempHome, 'middleware-codex-oauth');
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
try {
  const pinned = await readFile(path.join(root, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8');
  const kernelSHA = pinned.match(/PocketKernel: \x60([a-f0-9]{40})\x60/)?.[1];
  const middlewareSHA = pinned.match(/MiddlewareAuth: \x60([a-f0-9]{40})\x60/)?.[1];
  if (!kernelSHA || !middlewareSHA || gitSHA(kernelRoot) !== kernelSHA || gitSHA(middlewareRoot) !== middlewareSHA) {
    throw new Error('helper checkout diverge dos SHAs imutáveis registrados');
  }
  const kernelSource = path.join(tempHome, 'sources', 'pocketkernel');
  const middlewareSource = path.join(tempHome, 'sources', 'middlewareauth');
  await exportCleanSnapshot(kernelRoot, kernelSource);
  await exportCleanSnapshot(middlewareRoot, middlewareSource);
  const built = buildHelpers({ kernelRoot: kernelSource, middlewareRoot: middlewareSource, kernelBinary, middlewareBinary, tempHome });
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
    NH_TEST_POCKETWIKI_PORT: String(pocketWikiPort),
    POCKETWIKI_POCKETKERNEL_BINARY: kernelBinary,
    POCKETWIKI_MIDDLEWARE_AUTH_BINARY: middlewareBinary,
    POCKETWIKI_NODE_BINARY: process.execPath,
    MIDDLEWAREAUTH_BASE_URL: middlewareURL,
    POCKETKERNEL_MIDDLEWAREAUTH_BASE_URL: middlewareURL,
    LMSTUDIO_BASE_URL: providerURL,
    MCP_LMSTUDIO_MODEL: 'nh-test-model'
  };
  const args = [
    'test', '-project', project,
    '-scheme', 'PocketWikiMacNHTestHost',
    '-destination', 'platform=macOS',
    '-resultBundlePath', resultBundle
  ];
  const run = await runAndCapture(xcodebuild, args, root, env);
  output += run.output;
  status = run.status;
  if (status === 0 && !providerRequests.some((item) => item.prompt_contains_wiki_marker && item.authorized && item.model === 'nh-test-model')) {
    status = 1;
    output += '\nFAIL: XCTest terminou sem requisição fixture autenticada contendo evidência da wiki.\n';
  }
  output += '\nProvider fixture requests: ' + JSON.stringify(providerRequests) + '\n';
} catch (error) {
  output += '\nHost failure: ' + error.message + '\n';
  status = error.message.startsWith('não foi possível compilar') ? 2 : 1;
} finally {
  if (provider.listening) await new Promise((resolve) => provider.close(resolve));
  await writeFile(logPath, output, 'utf8');
  process.stdout.write(output);
  await makeWritable(tempHome);
  await rm(tempHome, { recursive: true, force: true });
}
process.exit(status);

function buildHelpers({ kernelRoot, middlewareRoot, kernelBinary, middlewareBinary, tempHome }) {
  const common = { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 };
  const env = { ...process.env, HOME: tempHome, CGO_ENABLED: '0', GOCACHE: path.join(tempHome, 'go-cache'), GOPATH: path.join(tempHome, 'go') };
  const kernel = spawnSync('go', ['build', '-mod=readonly', '-o', kernelBinary, './cmd/pocketkernel'], { ...common, cwd: kernelRoot, env });
  if (kernel.status !== 0) return { status: kernel.status ?? 2, output: '--- go build PocketKernel ---\n' + (kernel.stdout || '') + (kernel.stderr || kernel.error?.message || '') };
  const middleware = spawnSync('go', ['build', '-mod=readonly', '-o', middlewareBinary, './cmd/middleware-codex-oauth'], { ...common, cwd: middlewareRoot, env });
  if (middleware.status !== 0) return { status: middleware.status ?? 2, output: '--- go build MiddlewareAuth ---\n' + (middleware.stdout || '') + (middleware.stderr || middleware.error?.message || '') };
  return { status: 0, output: '' };
}

function gitSHA(repository) {
  const result = spawnSync('git', ['-C', repository, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('git checkout indisponível: ' + repository);
  return result.stdout.trim();
}

async function exportCleanSnapshot(repository, destination) {
  const status = spawnSync('git', ['-C', repository, 'status', '--porcelain=v1', '-z', '--untracked-files=all'], { encoding: 'utf8' });
  if (status.status !== 0) throw new Error('não foi possível verificar o checkout helper: ' + repository);
  const untracked = new Set();
  for (const record of status.stdout.split('\0').filter(Boolean)) {
    if (record.startsWith('?? ')) untracked.add(record.slice(3));
    else throw new Error('arquivos rastreados alterados no helper: ' + repository);
  }
  await cp(repository, destination, { recursive: true, filter(source) {
    const relative = path.relative(repository, source);
    if (!relative || relative === '.') return true;
    const segments = relative.split(path.sep);
    if (segments.includes('.git') || segments.includes('bin') || segments.includes('node_modules') || segments.includes('.build') || segments.includes('target')) return false;
    if (segments.some((segment) => segment === '.env' || segment.startsWith('.env.'))) return false;
    return ![...untracked].some((entry) => relative === entry || relative.startsWith(entry + path.sep));
  } });
}

async function makeWritable(target) {
  let info;
  try { info = await lstat(target); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (info.isSymbolicLink()) return;
  await chmod(target, info.isDirectory() ? 0o700 : 0o600);
  if (info.isDirectory()) for (const entry of await readdir(target)) await makeWritable(path.join(target, entry));
}

function runAndCapture(command, args, cwd, env) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
    child.once('error', (error) => resolve({ status: 2, output: 'Falha ao iniciar xcodebuild: ' + error.message + '\n' }));
    child.once('exit', (code, signal) => resolve({ status: code ?? 2, output: output + (signal ? '\nxcodebuild signal: ' + signal + '\n' : '') }));
  });
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
