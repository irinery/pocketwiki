import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { watch } from 'node:fs';
import { createServer } from 'node:http';
import { createInterface } from 'node:readline';
import { chmod, cp, lstat, mkdtemp, mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const temp = await mkdtemp(path.join(os.tmpdir(), 'pocketwiki-nh-test-web-'));
const wiki = path.join(temp, 'wiki');
const memory = path.join(temp, 'memory');
const envFile = path.join(temp, 'pocketwiki.env');
const readyFile = path.join(temp, 'pocketwiki-ready.json');
let host;
let browser;
let page;
let traceStarted = false;
let traceStopped = false;
let artifactDir;
let evidenceChild;
let bridges;
let uiKernelRequest;
const services = [];
const bridgesTranscript = { requests: [] };
let provider;

try {
  await mkdir(wiki, { recursive: true });
  await mkdir(memory, { recursive: true });
  await writeFile(path.join(wiki, 'index.md'), '---\ntitle: NH-TEST fixture page\nstatus: validated\ntrust: high\n---\n\n# NH-TEST fixture page\n\nfixture evidence: nh-test-marker-2026\n');
  await writeFile(envFile, [
    'POCKETWIKI_REFERENCE_PATH=' + wiki,
    'POCKETWIKI_REFERENCE_READONLY=true',
    'POCKETWIKI_MEMORY_PATH=' + memory,
    'POCKETWIKI_MEMORY_TOKEN=' + 'nh-test-memory-token-' + 'x'.repeat(32),
    'POCKETWIKI_MDNS=false',
    'POCKETKERNEL_BASE_URL=http://127.0.0.1:8080',
    'MIDDLEWARE_BASE_URL=http://127.0.0.1:18787',
    'MIDDLEWARE_PROJECT_ID=pocketwiki-nh-test',
    'MIDDLEWARE_CLIENT_TOKEN=dev-middleware-token-for-tests-only',
    ''
  ].join('\n'));

  bridges = await startRealBridges(temp, wiki);
  services.push(...bridges.children);
  const envLines = [
    'POCKETWIKI_REFERENCE_PATH=' + wiki,
    'POCKETWIKI_REFERENCE_READONLY=true',
    'POCKETWIKI_MEMORY_PATH=' + memory,
    'POCKETWIKI_MEMORY_TOKEN=' + 'nh-test-memory-token-' + 'x'.repeat(32),
    'POCKETWIKI_MDNS=false',
    'POCKETKERNEL_BASE_URL=' + bridges.kernelURL,
    'MIDDLEWARE_BASE_URL=' + bridges.middlewareURL,
    'MIDDLEWARE_PROJECT_ID=pocketwiki-nh-test',
    'MIDDLEWARE_CLIENT_TOKEN=' + bridges.middlewareToken,
    ''
  ].join('\n');
  await writeFile(envFile, envLines);

  const hostEnvironment = {
    PATH: process.env.PATH,
    HOME: temp,
    TMPDIR: temp,
    POCKETWIKI_ENV_PATH: envFile,
    POCKETWIKI_PORT: '0',
    POCKETWIKI_BIND_HOST: '127.0.0.1',
    POCKETWIKI_MDNS: 'false',
    NH_TEST_READY_FILE: readyFile
  };
  host = await startHost(hostEnvironment);
  const response = await fetch(host.baseURL);
  assert(response.ok, 'legacy web root returned HTTP ' + response.status);
  const html = await response.text();
  assert(html.includes('PocketWiki'), 'real legacy cockpit HTML did not load');
  const iconResponse = await fetch(new URL('/assets/favicon.png', host.baseURL));
  assert(iconResponse.ok && iconResponse.headers.get('content-type')?.includes('image/png'), 'legacy cockpit favicon alias is unavailable');

  const filesResponse = await fetch(new URL('/api/wiki/files', host.baseURL));
  assert(filesResponse.ok, '/api/wiki/files returned HTTP ' + filesResponse.status);
  const files = await filesResponse.json();
  assert(files.available === true, 'temporary wiki store is not available');
  assert(files.files.some((file) => file.path === 'index.md'), 'fixture wiki document is absent from real API');

  const configResponse = await fetch(new URL('/api/config', host.baseURL));
  const config = await configResponse.json();
  assert(config.mcpEvidence && config.mcpEvidence.available === true, 'real PocketWiki host did not expose MCP Evidence');
  const evidence = await callEvidence(wiki);
  assert(evidence.search.structuredContent.ok === true, 'MCP Evidence wiki.search did not return a positive result');
  assert(evidence.search.structuredContent.results.some((item) => item.snippet.toLowerCase().includes('nh test marker 2026')), 'MCP Evidence did not retrieve the local fixture');

  artifactDir = process.env.NH_TEST_ARTIFACT_DIR || temp;
  await mkdir(artifactDir, { recursive: true });
  browser = await chromium.launchPersistentContext(path.join(temp, 'browser-profile'), { headless: true, acceptDownloads: false });
  await browser.tracing.start({ screenshots: true, snapshots: true, sources: false });
  traceStarted = true;
  page = await browser.newPage();
  const externalRequests = [];
  await page.route('**/*', async (route) => {
    if (new URL(route.request().url()).origin !== new URL(host.baseURL).origin) {
      externalRequests.push(route.request().url());
      await route.abort('blockedbyclient');
      return;
    }
    await route.continue();
  });
  page.on('request', (request) => {
    if (new URL(request.url()).origin !== new URL(host.baseURL).origin && !externalRequests.includes(request.url())) externalRequests.push(request.url());
  });
  await page.route('**/api/kernel/query', async (route) => {
    try { uiKernelRequest = JSON.parse(route.request().postData() || '{}'); } catch { uiKernelRequest = { parse_error: true }; }
    await route.continue();
  });
  await page.goto(host.baseURL, { waitUntil: 'domcontentloaded' });
  await page.locator('body').waitFor({ state: 'visible' });
  await page.evaluate(() => {
    localStorage.setItem('pocketwiki:ai-provider-method', 'lmstudio');
    localStorage.setItem('pocketwiki:ai-model', 'nh-test-fixture-model');
    sessionStorage.setItem('pocketwiki:memory-token', 'nh-test-memory-token-' + 'x'.repeat(32));
  });
  await page.reload({ waitUntil: 'domcontentloaded' });
  assert((await page.title()).length > 0, 'legacy cockpit page has no title');
  assert(externalRequests.length === 0, 'legacy page attempted external network access: ' + externalRequests.join(','));
  await page.locator('.tab[data-panel="ai"]').click();
  await page.locator('.ai-side-toggle[data-ai-side="llm"]').click();
  await page.locator('#ai-method').selectOption('lmstudio');
  await page.locator('#ai-open-settings').click();
  await page.locator('#ai-settings-method').selectOption('lmstudio');
  await page.locator('#ai-settings-model').fill('nh-test-fixture-model');
  await page.locator('#ai-settings-base-url').fill(bridges.providerURL);
  await page.locator('#ai-settings-api-key').fill('nh-test-provider-key');
  await page.locator('#ai-settings-kernel-base-url').fill(bridges.kernelURL);
  await page.locator('#ai-settings-middleware-base-url').fill(bridges.middlewareURL);
  await page.locator('#ai-settings-project-id').fill('pocketwiki-nh-test');
  await page.locator('#ai-settings-profile-id').fill('default');
  await page.locator('#ai-settings-token').fill(bridges.middlewareToken);
  await page.locator('#ai-settings-memory-token').fill('nh-test-memory-token-' + 'x'.repeat(32));
  await page.locator('#ai-settings-save').click();
  await page.locator('#ai-connect').click();
  await page.locator('.ai-status').filter({ hasText: 'autenticado' }).waitFor({ state: 'visible' });
  await page.locator('#ai-question').fill('Qual é o status do marcador fixture evidence registrado na wiki?');
  await page.locator('#ai-send').click();
  const answer = page.locator('.ai-msg.assistant .ai-msg-content');
  await answer.filter({ hasText: 'nh-test fixture response' }).waitFor({ state: 'visible' });
  assert(bridges.transcript.requests.length === 1, 'provider fixture did not receive exactly one real bridge request');
  assert(bridges.transcript.requests[0].hasQuestion, 'MiddlewareAuth provider boundary did not receive the UI question');
  assert(bridges.transcript.requests[0].hasWikiMarker, 'PocketKernel did not include MCP Evidence from the temporary wiki');
  assert(uiKernelRequest?.model_id === 'nh-test-fixture-model', 'legacy UI did not send the selected provider fixture model to PocketKernel');

  const firstHostPID = host.child.pid;
  const firstHostProcess = host.child;
  const wikiPort = new URL(host.baseURL).port;
  await terminate(firstHostProcess);
  assert(firstHostProcess.exitCode !== null || firstHostProcess.signalCode !== null, 'PocketWiki process did not exit before restart');
  host = await startHost({ ...hostEnvironment, POCKETWIKI_PORT: wikiPort });
  assert(host.child !== firstHostProcess, 'PocketWiki restart did not create a new process handle');
  const restartedWikiResponse = await fetch(new URL('/api/wiki/files', host.baseURL));
  assert(restartedWikiResponse.ok, 'PocketWiki did not serve the wiki store after process restart');
  const restartedFiles = await restartedWikiResponse.json();
  assert(restartedFiles.files.some((file) => file.path === 'index.md'), 'wiki store contents were lost after PocketWiki process restart');

  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.locator('.tab[data-panel="ai"]').click();
  await page.locator('.ai-msg.assistant .ai-msg-content').filter({ hasText: 'nh-test fixture response' }).waitFor({ state: 'visible' });
  await page.screenshot({ path: path.join(artifactDir, 'legacy-web.png'), fullPage: true });
  await writeFile(path.join(artifactDir, 'legacy-web-evidence.json'), JSON.stringify({
    version: '0.2.0',
    surface: 'web',
    wiki_file: 'index.md',
    mcp_tools: evidence.tools,
    mcp_search_match: true,
    middlewareauth_health: true,
    pocketkernel_ready: true,
    provider_fixture_requests: bridges.transcript.requests.length,
    provider_fixture_received_wiki_marker: bridges.transcript.requests.some((item) => item.hasWikiMarker),
    pocketwiki_process_restarted: true,
    pocketwiki_pid_before_restart: firstHostPID,
    pocketwiki_pid_after_restart: host.child.pid,
    wiki_store_restored_after_process_restart: restartedFiles.files.some((file) => file.path === 'index.md'),
    answer_restored_after_reload: true,
    external_browser_requests: externalRequests.length
  }, null, 2) + '\n');
  await writeFile(path.join(artifactDir, 'legacy-web-process.log'), redactSecrets(
    '--- MiddlewareAuth ---\n' + bridges.transcript.middlewareLogs.join('') +
    '--- PocketKernel ---\n' + bridges.transcript.kernelLogs.join('')
  ));
  const tracePath = path.join(artifactDir, 'legacy-web-trace.zip');
  await browser.tracing.stop({ path: tracePath });
  traceStopped = true;
  await redactTraceArchive(tracePath, temp, [bridges.middlewareToken, 'nh-test-provider-key', 'nh-test-memory-token-' + 'x'.repeat(32)]);
  console.log('LEGACY-00/web real PocketWiki + PocketKernel + MiddlewareAuth bridge and restore passed');
} catch (error) {
  if (artifactDir && bridges) {
    await writeFile(path.join(artifactDir, 'legacy-web-failure-evidence.json'), JSON.stringify({
      provider_fixture_requests: bridges.transcript.requests,
      kernel_request: uiKernelRequest,
      middleware_logs: bridges.transcript.middlewareLogs,
      kernel_logs: bridges.transcript.kernelLogs,
      failure: String(error?.message || error).replace(/nh-test-provider-key|dev-middleware-token-for-tests-only/g, '[REDACTED]')
    }, null, 2) + '\n');
  }
  if (page && artifactDir) await page.screenshot({ path: path.join(artifactDir, 'legacy-web-failure.png'), fullPage: true }).catch(() => {});
  if (browser && traceStarted && !traceStopped && artifactDir) {
    const tracePath = path.join(artifactDir, 'legacy-web-trace.zip');
    await browser.tracing.stop({ path: tracePath }).catch(() => {});
    traceStopped = true;
    await redactTraceArchive(tracePath, temp, [
      'dev-middleware-token-for-tests-only',
      'nh-test-provider-key',
      'nh-test-memory-token-' + 'x'.repeat(32)
    ]).catch(() => {});
  }
  throw error;
} finally {
  if (browser) await browser.close();
  if (evidenceChild && evidenceChild.exitCode === null && evidenceChild.signalCode === null) await terminate(evidenceChild);
  if (host && host.child.exitCode === null && host.child.signalCode === null) await terminate(host.child);
  for (const child of services.reverse()) if (child.exitCode === null && child.signalCode === null) await terminate(child);
  if (provider) await new Promise((resolve) => provider.close(resolve));
  await makeWritable(temp);
  await rm(temp, { recursive: true, force: true });
}

async function startRealBridges(tempRoot, wikiRoot) {
  const kernelRoot = process.env.POCKETKERNEL_NH00_ROOT || path.resolve(root, '../pocketkernel-nh00');
  const middlewareRoot = process.env.MIDDLEWAREAUTH_NHTEST_ROOT || path.resolve(root, '../middlewareAuth');
  const pinned = await readFile(path.join(root, 'docs/rfcs/new-harness/nhtest-base-shas.md'), 'utf8');
  const kernelSHA = pinned.match(/PocketKernel: \x60([a-f0-9]{40})\x60/)?.[1];
  const middlewareSHA = pinned.match(/MiddlewareAuth: \x60([a-f0-9]{40})\x60/)?.[1];
  assert(kernelSHA && gitSHA(kernelRoot) === kernelSHA, 'PocketKernel checkout differs from the registered immutable SHA');
  assert(middlewareSHA && gitSHA(middlewareRoot) === middlewareSHA, 'MiddlewareAuth checkout differs from the registered immutable SHA');
  const kernelSource = await exportGitSnapshot(kernelRoot, kernelSHA, path.join(tempRoot, 'sources', 'pocketkernel'));
  const middlewareSource = await exportGitSnapshot(middlewareRoot, middlewareSHA, path.join(tempRoot, 'sources', 'middlewareauth'));
  const goEnv = { ...process.env, HOME: tempRoot, GOPATH: path.join(tempRoot, 'go'), GOCACHE: path.join(tempRoot, 'go-cache'), GOPROXY: process.env.GOPROXY || 'https://proxy.golang.org,direct' };
  const middlewareBin = path.join(tempRoot, 'middlewareauth');
  const kernelBin = path.join(tempRoot, 'pocketkernel');
  runChecked('go', ['build', '-o', middlewareBin, './cmd/middleware-codex-oauth'], middlewareSource, goEnv);
  runChecked('go', ['build', '-o', kernelBin, './cmd/pocketkernel'], kernelSource, goEnv);
  provider = createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      if (req.url === '/v1/models' && req.method === 'GET') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ data: [{ id: 'nh-test-fixture-model', object: 'model' }] }));
        return;
      }
      if (req.url === '/v1/chat/completions' && req.method === 'POST') {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
        const combined = JSON.stringify(body.messages || []);
        bridgesTranscript.requests.push({
          hasQuestion: combined.includes('Qual é o status do marcador fixture evidence registrado na wiki?'),
          hasWikiMarker: combined.includes('nh-test-marker-2026')
        });
        if (!bridgesTranscript.requests.at(-1)?.hasWikiMarker) {
          res.writeHead(422, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'fixture_requires_pocketwiki_marker' }));
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'nh-test-fixture-response', object: 'chat.completion', model: 'nh-test-fixture-model', choices: [{ index: 0, message: { role: 'assistant', content: 'nh-test fixture response: nh-test-marker-2026' }, finish_reason: 'stop' }] }));
        return;
      }
      res.writeHead(404, { 'content-type': 'application/json' }); res.end('{"error":"not_found"}');
    });
  });
  const providerPort = await listenEphemeral(provider);
  const providerURL = 'http://127.0.0.1:' + providerPort;
  const middlewarePort = await freePort();
  const middlewareToken = 'dev-middleware-token-for-tests-only';
  const middlewareState = path.join(tempRoot, 'middleware-state');
  const middlewareEnv = {
    ...goEnv,
    NODE_ENV: 'test',
    MIDDLEWARE_STATE_DIR: middlewareState,
    HTTP_BIND_ADDR: '127.0.0.1',
    HTTP_PORT: String(middlewarePort),
    OAUTH_CALLBACK_HOST: '127.0.0.1',
    OAUTH_CALLBACK_PORT: String(middlewarePort),
    MIDDLEWARE_ALLOWED_AUTH_HOSTS: 'auth.openai.com,127.0.0.1,localhost',
    MIDDLEWARE_ALLOWED_CODEX_HOSTS: 'chatgpt.com,127.0.0.1,localhost',
    MIDDLEWARE_REDACT_LOGS: 'true'
  };
  const middleware = spawn(middlewareBin, [], { cwd: tempRoot, env: middlewareEnv, stdio: ['ignore', 'pipe', 'pipe'] });
  const middlewareLogs = [];
  middleware.stderr.on('data', (chunk) => middlewareLogs.push(chunk.toString()));
  await awaitReadyLine(middleware, /middleware iniciado/);
  const middlewareURL = 'http://127.0.0.1:' + middlewarePort;
  await ensureHTTP(middlewareURL + '/healthz', middleware);
  const configure = await fetch(middlewareURL + '/v1/projects/pocketwiki-nh-test/auth/lmstudio/api-key', {
    method: 'POST', headers: { authorization: 'Bearer ' + middlewareToken, 'content-type': 'application/json' },
    body: JSON.stringify({ profileId: 'default', baseUrl: providerURL, apiKey: 'nh-test-provider-key' })
  });
  assert(configure.ok, 'real MiddlewareAuth rejected the isolated provider fixture setup (' + configure.status + ')');
  const kernelPort = await freePort();
  const kernelURL = 'http://127.0.0.1:' + kernelPort;
  const kernelEnv = {
    ...goEnv,
    POCKETKERNEL_TRACE: '1',
    POCKETKERNEL_LLM_TRANSPORT: 'middlewareauth',
    POCKETKERNEL_MIDDLEWAREAUTH_BASE_URL: middlewareURL,
    POCKETKERNEL_MIDDLEWAREAUTH_PROJECT_ID: 'pocketwiki-nh-test',
    POCKETKERNEL_MIDDLEWAREAUTH_CLIENT_TOKEN: middlewareToken,
    POCKETKERNEL_WIKI_MCP_COMMAND: process.execPath,
    POCKETKERNEL_WIKI_MCP_ARGS: path.join(root, 'src/mcp/pocketwiki-mcp-server.mjs') + ' --root ' + wikiRoot
  };
  const kernel = spawn(kernelBin, ['-mode', 'serve', '-addr', '127.0.0.1:' + kernelPort, '-llm-transport', 'middlewareauth', '-middlewareauth-base-url', middlewareURL, '-middlewareauth-project-id', 'pocketwiki-nh-test', '-middlewareauth-client-token', middlewareToken], { cwd: tempRoot, env: kernelEnv, stdio: ['ignore', 'pipe', 'pipe'] });
  const kernelLogs = [];
  kernel.stderr.on('data', (chunk) => kernelLogs.push(chunk.toString()));
  await awaitReadyLine(kernel, /PocketKernel HTTP ouvindo/);
  bridgesTranscript.providerURL = providerURL;
  bridgesTranscript.middlewareLogs = middlewareLogs;
  bridgesTranscript.kernelLogs = kernelLogs;
  return { children: [middleware, kernel], middlewareURL, kernelURL, providerURL, middlewareToken, transcript: bridgesTranscript };
}

async function startHost(env) {
  const readyDirectory = path.dirname(env.NH_TEST_READY_FILE);
  const readyName = path.basename(env.NH_TEST_READY_FILE);
  await rm(env.NH_TEST_READY_FILE, { force: true });
  const readyWatcher = watch(readyDirectory);
  const child = spawn(process.execPath, ['server.mjs'], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout });
  const stderr = [];
  child.stderr.on('data', (data) => stderr.push(data.toString()));
  try {
    const ready = await new Promise((resolve, reject) => {
    const finishIfReady = async () => {
      try {
        const contents = await readFile(env.NH_TEST_READY_FILE, 'utf8');
        resolve(JSON.parse(contents));
      } catch {}
    };
    readyWatcher.on('change', (eventType, filename) => {
      if (filename?.toString() === readyName) void finishIfReady();
    });
    void finishIfReady();
    child.once('error', reject);
    child.once('exit', (code) => reject(new Error('PocketWiki exited before ready (' + code + '): ' + stderr.join(''))));
    });
    return { child, lines, baseURL: ready.http };
  } catch (error) {
    readyWatcher.close();
    if (child.exitCode === null && child.signalCode === null) await terminate(child);
    throw error;
  } finally {
    readyWatcher.close();
  }
}

async function callEvidence(wikiRoot) {
  evidenceChild = spawn(process.execPath, ['src/mcp/pocketwiki-mcp-server.mjs', '--root', wikiRoot], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = createInterface({ input: evidenceChild.stdout });
  const pending = new Map();
  lines.on('line', (line) => {
    const response = JSON.parse(line);
    const entry = pending.get(response.id);
    if (entry) { pending.delete(response.id); entry.resolve(response); }
  });
  let id = 0;
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const requestID = ++id;
    const timeout = setTimeout(() => { pending.delete(requestID); reject(new Error('MCP Evidence timeout on ' + method)); }, 5000);
    pending.set(requestID, {
      resolve(value) { clearTimeout(timeout); resolve(value); },
      reject
    });
    evidenceChild.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: requestID, method, params }) + '\n');
  });
  await call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'nh-test', version: '0.2.0' } });
  const tools = await call('tools/list');
  assert(tools.result.tools.some((tool) => tool.name === 'wiki.search'), 'MCP Evidence is missing wiki.search');
  const search = await call('tools/call', { name: 'wiki.search', arguments: { query: 'nh-test-marker-2026' } });
  evidenceChild.stdin.end();
  await once(evidenceChild, 'exit');
  return { tools: tools.result.tools.map(({ name }) => name), search: search.result };
}

async function terminate(child) {
  const exited = once(child, 'exit').then(() => true);
  child.kill('SIGTERM');
  if (await Promise.race([exited, delay(1000).then(() => false)])) return;
  child.kill('SIGKILL');
  await exited;
}
function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function makeWritable(target) {
  let info;
  try { info = await lstat(target); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (info.isSymbolicLink()) return;
  await chmod(target, info.isDirectory() ? 0o700 : 0o600);
  if (info.isDirectory()) for (const entry of await readdir(target)) await makeWritable(path.join(target, entry));
}
async function redactTraceArchive(archivePath, tempRoot, secrets) {
  const unpacked = path.join(tempRoot, 'trace-unpacked');
  await mkdir(unpacked, { recursive: true });
  const unpack = spawnSync('unzip', ['-q', archivePath, '-d', unpacked], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  if (unpack.status !== 0) throw new Error('could not unpack Playwright trace for redaction');
  async function redactDirectory(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await redactDirectory(file);
      else if (/\.(trace|network|json|txt)$/.test(entry.name)) {
        let content = await readFile(file, 'utf8');
        for (const secret of secrets) if (secret) content = content.split(secret).join('[REDACTED]');
        content = content.replace(/nh-test-memory-token-[A-Za-z0-9-]*/g, '[REDACTED]');
        await writeFile(file, content);
      }
    }
  }
  await redactDirectory(unpacked);
  const sanitized = path.join(tempRoot, 'trace-redacted.zip');
  const zipped = spawnSync('zip', ['-qr', sanitized, '.'], { cwd: unpacked, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  if (zipped.status !== 0 || (await stat(sanitized)).size === 0) throw new Error('could not repackage redacted Playwright trace: ' + (zipped.stderr || 'empty archive'));
  await rename(sanitized, archivePath);
}
function assert(condition, message) { if (!condition) throw new Error(message); }
function redactSecrets(value) {
  return String(value)
    .replace(/dev-middleware-token-for-tests-only/g, '[REDACTED]')
    .replace(/nh-test-provider-key/g, '[REDACTED]')
    .replace(/nh-test-memory-token-[A-Za-z0-9-]*/g, '[REDACTED]');
}
function gitSHA(cwd) {
  const result = spawnSync('git', ['-C', cwd, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error('git SHA unavailable for ' + cwd);
  return result.stdout.trim();
}
function runChecked(binary, args, cwd, env) {
  const result = spawnSync(binary, args, { cwd, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 180_000 });
  if (result.status !== 0) throw new Error(binary + ' ' + args.join(' ') + ' failed (' + result.status + '): ' + (result.stderr || result.error?.message || ''));
}
async function exportGitSnapshot(repository, sha, destination) {
  const status = spawnSync('git', ['-C', repository, 'status', '--porcelain=v1', '-z', '--untracked-files=all'], { encoding: 'utf8' });
  if (status.status !== 0) throw new Error('cannot verify pinned source status: ' + repository);
  const untracked = new Set();
  for (const record of status.stdout.split('\0').filter(Boolean)) {
    if (record.startsWith('?? ')) untracked.add(record.slice(3));
    else throw new Error('tracked source files are dirty in ' + repository + '; refusing a non-pinned build');
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
function listenEphemeral(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}
async function freePort() {
  const probe = createServer();
  const port = await listenEphemeral(probe);
  await new Promise((resolve, reject) => probe.close((error) => error ? reject(error) : resolve()));
  return port;
}
async function awaitReadyLine(child, pattern) {
  const text = [];
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error('service did not signal readiness')), 15_000);
    const onError = (error) => finish(error);
    const onExit = (code) => finish(new Error('service exited before ready (' + code + '): ' + text.join('')));
    const onData = (chunk) => {
      text.push(chunk.toString());
      if (pattern.test(text.join(''))) finish();
    };
    function finish(error) {
      clearTimeout(timer);
      child.stderr.off('data', onData);
      child.off('error', onError);
      child.off('exit', onExit);
      error ? reject(error) : resolve();
    }
    child.stderr.on('data', onData);
    child.once('error', onError);
    child.once('exit', onExit);
  });
}
async function ensureHTTP(url, child) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(3000) });
    assert(response.ok, url + ' returned HTTP ' + response.status);
  } catch (error) {
    throw new Error('service readiness HTTP check failed for ' + url + ': ' + error.message + '; stderr=' + child.stderr.read()?.toString());
  }
}
