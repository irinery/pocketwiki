import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { fixtureUUID } from './fixture-ids.mjs';
import { requireRuntimeScreenshot } from './runtime-proof.mjs';
import { sanitizeWebTrace } from './web-trace.mjs';
import { sanitizeRuntimeScreenshot } from '../../NewHarnessE2E/MacOSHost/runtime-screenshot.mjs';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { build } from 'esbuild';
import { chromium } from '@playwright/test';
import { Transform } from 'node:stream';
import { KernelLocalBootstrapClient } from '../../../src/harness/kernel-bootstrap.mjs';
import { RuntimeTransport } from '../../../src/harness/runtime/transport.mjs';
import { runtimeFrames } from '../../../src/harness-ui/runtime/sse.mjs';
import { LocalCredentialHost } from '../../../src/harness/local-host.mjs';

const binary = process.env.RUNTIME_KERNEL_BINARY;
const pauseEffect = process.env.RUNTIME_PAUSE_EFFECT === '1';
const incompatible = process.env.RUNTIME_INCOMPATIBLE === '1';
const replay = process.env.RUNTIME_REPLAY === '1';
const legacy = process.env.RUNTIME_LEGACY === '1';
const macos = process.env.RUNTIME_MACOS === '1';
let releaseStream;
if (!binary) throw new Error('RUNTIME_KERNEL_BINARY obrigatório');
const tmp = await mkdtemp(path.join(os.tmpdir(), 'e1-ui-')); const socketPath = path.join(tmp, 'boot.sock');
const io = path.join(tmp, 'io'); await mkdir(io);
const seed = Number(process.env.NH_TEST_SEED ?? '20261102');
const fixtureScope = replay ? 'replay' : incompatible ? 'incompatible' : pauseEffect ? 'accepted' : legacy ? 'legacy' : 'connect';
const fixtureID = label => fixtureUUID(seed, `${macos ? 'macos' : 'web'}/${fixtureScope}/${label}`);
const principalId = fixtureID('principal'), environmentId = fixtureID('environment'), threadId = fixtureID('thread');
const commandIds = Array.from({ length: 16 }, (_, index) => fixtureID(`ui-command-${index}`));
const audience = 'pocketkernel.harness.v1';
const schemaSHA256 = createHash('sha256').update(await readFile('src/harness/contracts/harness-v1.schema.json')).digest('hex');
const buildResult = await build({ entryPoints: ['Tests/HarnessUI/runtime/web/main.mjs'], bundle: true, format: 'esm', platform: 'browser', inject: ['Tests/HarnessUI/runtime/web/buffer-shim.mjs'], write: false });
const child = spawn(binary, ['-mode','serve','-mock-model','-addr','127.0.0.1:0','-harness-rig-ready','-harness-db',path.join(tmp,'runtime.db'),'-harness-auth-store',path.join(tmp,'auth.json'),'-harness-bootstrap-socket',socketPath,'-harness-temp-root',io,'-harness-audience',audience,'-harness-schema-sha256',schemaSHA256, ...(pauseEffect ? ['-harness-rig-pause-after-effect'] : [])], { stdio: ['ignore','pipe','pipe'] });
let browser, server, bootstrap, legacyChild, page, traceStarted = false, bearer, scenarioError;
try {
  const base = await new Promise((resolve, reject) => {
    for (const input of [child.stdout, child.stderr]) createInterface({input}).on('line', line => { const match = /^HARNESS_READY (127\.0\.0\.1:[0-9]+)$/.exec(line); if (match) resolve(`http://${match[1]}`); });
    child.once('error', reject); child.once('exit', code => reject(new Error(`Kernel exited ${code}`)));
  });
  const body = JSON.stringify({ environment_id: environmentId, thread_id: threadId, owner_principal_id: principalId });
  await new Promise((resolve, reject) => { const req = http.request({socketPath,path:'/v1/runtime/threads',method:'POST',headers:{'content-type':'application/json','content-length':Buffer.byteLength(body)}}, res => { res.resume(); res.once('end', () => res.statusCode === 204 ? resolve() : reject(new Error(`thread HTTP ${res.statusCode}`))); }); req.on('error',reject); req.end(body); });
  bootstrap = new KernelLocalBootstrapClient({ socketPath }); const scopes = ['read','submit'];
  await bootstrap.registerAggregateGrant({ principal_id: principalId, environment_id: environmentId, audience, aggregate_id: threadId, scopes });
  const credentialHost = new LocalCredentialHost({ principalId, environmentId, audience, grantedScopes: scopes, deliverBearer: async value => { bearer = value.bearer; }, persistVerifier: verifier => bootstrap.persistVerifier(verifier) });
  await credentialHost.bootstrap(scopes, { aggregateId: threadId });
  if (replay) {
    const transport = new RuntimeTransport({ baseURL: base, bearer });
    const abort = new AbortController();
    const stream = await transport.stream(threadId, 0, { signal: abort.signal });
    const frames = runtimeFrames(stream)[Symbol.asyncIterator]();
    const commandId = fixtureID('seed-command');
    await transport.dispatch({ protocol_major: 1, command_id: commandId, environment_id: environmentId, expected_revision: 0, operation: 'runtime.dispatch', input: { command_id: commandId, thread_id: threadId, expected_revision: 0, operation: 'submit', text: 'seed replay' } });
    for (;;) {
      const { value, done } = await frames.next();
      if (done) throw new Error('stream ended before seed effect');
      if (value.seq === 9) break;
    }
    abort.abort(); await frames.return();
    assert.equal((await transport.snapshot(threadId)).data.as_of_seq, 9);
  }
  let targetBase = base;
  if (legacy) {
    if (!process.env.RUNTIME_LEGACY_BINARY) throw new Error('RUNTIME_LEGACY_BINARY obrigatório');
    legacyChild = spawn(process.env.RUNTIME_LEGACY_BINARY, [], { stdio: ['ignore', 'pipe', 'pipe'] });
    targetBase = await new Promise((resolve, reject) => {
      createInterface({ input: legacyChild.stdout }).on('line', line => { const m = /^LEGACY_READY (127\.0\.0\.1:[0-9]+)$/.exec(line); if (m) resolve(`http://${m[1]}`); });
      legacyChild.once('error', reject); legacyChild.once('exit', code => reject(new Error(`legacy host exited ${code}`)));
    });
  }
  server = http.createServer((req,res) => {
    if (req.url === '/release-stream') { releaseStream?.(); res.writeHead(204); res.end(); return; }
    if (req.url === '/') { res.writeHead(200, {'content-type':'text/html'}); res.end('<main id="runtime-slot"></main>'); return; }
    if (req.url === '/bundle.js') { res.writeHead(200, {'content-type':'text/javascript'}); res.end(buildResult.outputFiles[0].contents); return; }
    const target = new URL(req.url, targetBase); const headers = { ...req.headers };
    if (replay && target.pathname.startsWith('/v1/harness/streams/')) { target.searchParams.set('after_seq', '7'); headers['last-event-id'] = '7'; }
    const upstream = http.request(target, { method:req.method, headers }, response => { res.writeHead(response.statusCode, response.headers); res.flushHeaders(); if (pauseEffect && req.url.startsWith('/v1/harness/streams/')) { response.pause(); releaseStream = () => response.pipe(res); }
      else if (incompatible && req.url.startsWith('/v1/harness/streams/')) {
        let pending = '', injected = false;
        const filter = new Transform({ transform(chunk, encoding, done) {
          pending += chunk.toString('utf8');
          for (;;) { const at = pending.indexOf('\n\n'); if (at < 0) break;
            let frame = pending.slice(0, at); pending = pending.slice(at + 2);
            if (!injected && frame.includes('data:')) {
              frame = frame.replace(/(data:\s*)(\{[^\n]*\})/, (_, prefix, json) => { const event = JSON.parse(json); event.protocol_major = 2; injected = true; return prefix + JSON.stringify(event); });
            }
            this.push(frame + '\n\n');
          }
          done();
        }}); response.pipe(filter).pipe(res);
      } else response.pipe(res); });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); }); req.pipe(upstream); res.on('close', () => upstream.destroy());
  });
  server.listen(0,'127.0.0.1'); await once(server,'listening');
  if (macos) {
    const configPath = path.join(tmp, 'native-config.json');
    await writeFile(configPath, JSON.stringify({ baseURL: `http://127.0.0.1:${server.address().port}`, bearer, environmentID: environmentId, threadID: threadId, schemaSHA256, schemaPath: path.resolve('src/harness/contracts/harness-v1.schema.json'), commandIDs: commandIds.join(','), commandID: commandIds[0], seedCommandID: fixtureID('seed-command'), observeFrames: replay ? '1' : '0' }), { mode: 0o600 });
    const scenario = replay ? 'replay' : incompatible ? 'incompatible' : pauseEffect ? 'accepted' : 'connect';
    const resultPath = path.join(tmp, `runtime-${scenario}.xcresult`);
    const test = spawn('xcodebuild', ['-resultBundlePath', resultPath, '-project', 'Tests/HarnessUI/runtime/macos/PocketWikiRuntimeUIHost.xcodeproj', '-scheme', 'PocketWikiRuntimeUIHost', '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', process.env.RUNTIME_DERIVED_DATA, 'test-without-building', 'CODE_SIGNING_ALLOWED=NO', '-quiet'], { env: { ...process.env, NH_RUNTIME_CONFIG_PATH: configPath, NH_RUNTIME_SCENARIO: scenario, NH_RUNTIME_TEST_FORCE_FAILURE: process.env.NH_RUNTIME_TEST_FORCE_FAILURE || '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = ''; for (const stream of [test.stdout, test.stderr]) stream.on('data', chunk => { output = (output + chunk.toString()).slice(-12000); });
    const [code] = await once(test, 'exit');
    if (process.env.RUNTIME_ARTIFACT_DIR) {
      const call = promisify(execFile);
      const { stdout } = await call('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', resultPath, '--format', 'json']);
      const summary = JSON.parse(stdout);
      await writeFile(path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${scenario}.summary.json`), JSON.stringify({ result: summary.result, totalTestCount: summary.totalTestCount, passedTests: summary.passedTests, failedTests: summary.failedTests, skippedTests: summary.skippedTests }, null, 2) + '\n', { mode: 0o600 });
      if (code === 0) {
      const attachments = path.join(tmp, `attachments-${scenario}`); await mkdir(attachments);
      await call('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resultPath, '--output-path', attachments, '--filter', 'runtime-fixture*']);
      const files = await readdir(attachments);
      const screenshot = files.find(file => file.toLowerCase().endsWith('.png'));
      if (!screenshot) throw new Error('captura de teste nativo ausente');
      const screenshotBytes = sanitizeRuntimeScreenshot(await readFile(path.join(attachments, screenshot)), { maxWidth: 4096, maxHeight: 2048 });
      requireRuntimeScreenshot(screenshotBytes, { maxHeight: 2048 });
      await writeFile(path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${scenario}.png`), screenshotBytes, { mode: 0o600 });
      } else {
        try {
          const attachments = path.join(tmp, `failure-attachments-${scenario}`); await mkdir(attachments);
          await call('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resultPath, '--output-path', attachments, '--filter', 'runtime-failure-slot*']);
          const files = (await readdir(attachments)).filter(file => file.toLowerCase().endsWith('.png'));
          if (files.length !== 1) throw new Error('slot fixture ausente ou ambíguo');
          const bytes = sanitizeRuntimeScreenshot(await readFile(path.join(attachments, files[0])), { maxWidth: 4096, maxHeight: 2048 });
          requireRuntimeScreenshot(bytes, { maxHeight: 2048 });
          await writeFile(path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${scenario}-failure.png`), bytes, { mode: 0o600 });
        } catch { console.error('Captura de falha macOS indisponível para slot fixture'); }
      }
    }
    if (code !== 0) throw new Error(`XCTest falhou (${code}): ${output}`);
    console.log(`macOS XCTest: ${scenario} validado`);
  } else {
  browser = await chromium.launch({headless:true}); page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async config => {
    const { mount } = await import('/bundle.js'); window.runtime = mount(config);
    window.seen = []; window.views = []; let wake;
    window.waitSeen = count => window.seen.length >= count ? Promise.resolve() : new Promise(resolve => { wake = { count, resolve }; });
    const original = window.runtime.client.applyEvent.bind(window.runtime.client);
    window.runtime.client.applyEvent = async (...args) => { await original(...args); window.seen.push(args[0].seq); window.views.push({ lastSeq: window.runtime.client.state.lastSeq, receipts: window.runtime.client.state.receipts.length }); if (wake && window.seen.length >= wake.count) { wake.resolve(); wake = null; } };
  }, { bearer, environmentId, threadId, schemaSHA256, commandIds, legacy });
  // Start after credential injection so the mount arguments never enter the trace.
  await page.context().tracing.start({ screenshots: false, snapshots: true, sources: false });
  traceStarted = true;
  await page.evaluate(async legacy => {
    try { await window.runtime.panel.open(); } catch (error) { if (!legacy) throw error; }
  }, legacy);
  if (process.env.RUNTIME_TEST_FORCE_FAILURE === '1') throw new Error('forced fixture failure');
  if (replay) {
    await page.evaluate(() => window.waitSeen(2));
    assert.deepEqual(await page.evaluate(() => window.seen.slice(0, 2)), [8, 9]);
    assert.equal(await page.evaluate(() => window.runtime.client.state.lastSeq), 9);
  }
  if (legacy) {
    await page.getByRole('status').getByText(/Execução durável indisponível/).waitFor();
    assert.equal(await page.getByRole('button', {name:'Enviar comando'}).isDisabled(), true);
    const result = await page.evaluate(async () => {
      const response = await fetch('/v1/kernel', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'O que são LLMs?', channel: 'web', app_id: 'pocketkernel', user_id: 'fixture' }) });
      return { status: response.status, body: await response.json() };
    });
    assert.equal(result.status, 200); assert.equal(result.body.ok, true);
    console.log('Chromium: capability 404 e API legada real acessível');
  } else {
  await page.getByLabel('Texto do comando durável').fill('efeito real web');
  await page.getByRole('button', {name:'Enviar comando'}).click();
  if (replay) {
    await page.evaluate(() => window.waitSeen(5));
    assert.deepEqual(await page.evaluate(() => window.seen.slice(0, 5)), [8, 9, 10, 11, 12]);
    assert.deepEqual(await page.evaluate(() => window.views.slice(0, 5).map(view => view.lastSeq)), [9, 9, 10, 11, 12]);
    assert.equal(await page.evaluate(() => window.views[1].receipts), 1);
    assert.equal(await page.evaluate(() => window.views[3].receipts), 2);
    const ids = await page.evaluate(() => window.runtime.client.state.receipts.map(receipt => receipt.command_id));
    assert.ok(ids.includes(fixtureID('seed-command')) && ids.includes(commandIds[0]));
    await page.evaluate(() => window.waitSeen(11));
    await page.getByLabel('Texto do comando durável').fill('segunda intenção');
    await page.getByRole('button', {name:'Enviar comando'}).click();
    await page.evaluate(() => window.waitSeen(14));
    const finalIDs = await page.evaluate(() => window.runtime.client.state.receipts.map(receipt => receipt.command_id));
    assert.ok(finalIDs.includes(commandIds[0]) && finalIDs.includes(commandIds[1]));
    assert.notEqual(commandIds[0], commandIds[1]);
  } else if (incompatible) {
    await page.getByRole('status').getByText('ERR_INCOMPATIBLE').waitFor({timeout:30000});
    assert.equal(await page.evaluate(() => window.runtime.client.state.lastSeq), 0);
  } else if (pauseEffect) {
    await page.getByText(/Aceito/).waitFor({timeout:30000});
    assert.equal(await page.locator('[data-completed="true"]').count(), 0);
    assert.ok((await page.locator('[aria-label="Recibos do runtime"]').innerText()).includes(commandIds[0]));
    if (process.env.RUNTIME_ARTIFACT_DIR) await page.locator('#runtime-slot').screenshot({ path: path.join(process.env.RUNTIME_ARTIFACT_DIR, 'runtime-accepted-before-release.png') });
    await page.evaluate(() => fetch('/release-stream', { method: 'POST' }));
  } else {
    await page.getByText(/Concluído/).waitFor({timeout:30000});
    assert.equal(await page.locator('[data-completed="true"]').count(), 1);
  }
  }
  if (process.env.RUNTIME_ARTIFACT_DIR) await page.screenshot({ path: path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${replay ? 'replay' : incompatible ? 'incompatible' : pauseEffect ? 'accepted' : legacy ? 'legacy' : 'connect'}.png`) });
  await page.evaluate(() => window.runtime.client.close());
  if (!legacy) console.log(replay ? 'Chromium: snapshot real 9 ignorou replay 8/9 e aplicou 10/11/12' : incompatible ? 'Chromium: versão incompatível recusada sem aplicar frame' : pauseEffect ? 'Chromium: receipt aceito antes da confirmação do efeito' : 'Chromium: bootstrap scoped, painel, dispatch e efeito real verificados');
  }
} catch (error) {
  scenarioError = error;
  if (page && process.env.RUNTIME_ARTIFACT_DIR) {
    try {
      const bytes = sanitizeRuntimeScreenshot(await page.locator('#runtime-slot').screenshot(), { maxWidth: 4096, maxHeight: 2048 });
      requireRuntimeScreenshot(bytes, { maxHeight: 2048 });
      await writeFile(path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${fixtureScope}-failure.png`), bytes, { mode: 0o600 });
    } catch (captureError) { console.error('Captura de falha indisponível:', captureError.message); }
  }
} finally {
  if (traceStarted) {
    try {
      const rawTrace = path.join(tmp, 'web-trace-raw.zip');
      await page.context().tracing.stop({ path: rawTrace });
      if (process.env.RUNTIME_ARTIFACT_DIR) await sanitizeWebTrace(rawTrace, tmp, path.join(process.env.RUNTIME_ARTIFACT_DIR, `runtime-${fixtureScope}-trace.zip`), [bearer]);
    } catch (error) {
      console.error('Falha ao sanitizar trace:', error.message);
      scenarioError ??= error;
    }
  }
  await browser?.close(); if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  bootstrap?.close(); if (legacyChild && legacyChild.exitCode === null) { const exited = once(legacyChild, 'exit'); legacyChild.kill('SIGTERM'); await exited; }
  if (child.exitCode === null) { const exited = once(child,'exit'); child.kill('SIGTERM'); await exited; }
  await rm(tmp,{recursive:true,force:true});
}

if (scenarioError) throw scenarioError;
