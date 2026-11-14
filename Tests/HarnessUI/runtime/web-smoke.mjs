import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { build } from 'esbuild';
import { chromium } from '@playwright/test';
import { Transform } from 'node:stream';
import { KernelLocalBootstrapClient } from '../../../src/harness/kernel-bootstrap.mjs';
import { LocalCredentialHost } from '../../../src/harness/local-host.mjs';

const binary = process.env.RUNTIME_KERNEL_BINARY;
const pauseEffect = process.env.RUNTIME_PAUSE_EFFECT === '1';
const incompatible = process.env.RUNTIME_INCOMPATIBLE === '1';
let releaseStream;
if (!binary) throw new Error('RUNTIME_KERNEL_BINARY obrigatório');
const tmp = await mkdtemp(path.join(os.tmpdir(), 'e1-ui-')); const socketPath = path.join(tmp, 'boot.sock');
const io = path.join(tmp, 'io'); await mkdir(io);
const principalId = randomUUID(), environmentId = randomUUID(), threadId = randomUUID();
const audience = 'pocketkernel.harness.v1';
const schemaSHA256 = createHash('sha256').update(await readFile('src/harness/contracts/harness-v1.schema.json')).digest('hex');
const buildResult = await build({ entryPoints: ['Tests/HarnessUI/runtime/web/main.mjs'], bundle: true, format: 'esm', platform: 'browser', inject: ['Tests/HarnessUI/runtime/web/buffer-shim.mjs'], write: false });
const child = spawn(binary, ['-mode','serve','-mock-model','-addr','127.0.0.1:0','-harness-rig-ready','-harness-db',path.join(tmp,'runtime.db'),'-harness-auth-store',path.join(tmp,'auth.json'),'-harness-bootstrap-socket',socketPath,'-harness-temp-root',io,'-harness-audience',audience,'-harness-schema-sha256',schemaSHA256, ...(pauseEffect ? ['-harness-rig-pause-after-effect'] : [])], { stdio: ['ignore','pipe','pipe'] });
let browser, server, bootstrap;
try {
  const base = await new Promise((resolve, reject) => {
    for (const input of [child.stdout, child.stderr]) createInterface({input}).on('line', line => { const match = /^HARNESS_READY (127\.0\.0\.1:[0-9]+)$/.exec(line); if (match) resolve(`http://${match[1]}`); });
    child.once('error', reject); child.once('exit', code => reject(new Error(`Kernel exited ${code}`)));
  });
  const body = JSON.stringify({ environment_id: environmentId, thread_id: threadId, owner_principal_id: principalId });
  await new Promise((resolve, reject) => { const req = http.request({socketPath,path:'/v1/runtime/threads',method:'POST',headers:{'content-type':'application/json','content-length':Buffer.byteLength(body)}}, res => { res.resume(); res.once('end', () => res.statusCode === 204 ? resolve() : reject(new Error(`thread HTTP ${res.statusCode}`))); }); req.on('error',reject); req.end(body); });
  bootstrap = new KernelLocalBootstrapClient({ socketPath }); const scopes = ['read','submit'];
  await bootstrap.registerAggregateGrant({ principal_id: principalId, environment_id: environmentId, audience, aggregate_id: threadId, scopes });
  let bearer; const credentialHost = new LocalCredentialHost({ principalId, environmentId, audience, grantedScopes: scopes, deliverBearer: async value => { bearer = value.bearer; }, persistVerifier: verifier => bootstrap.persistVerifier(verifier) });
  await credentialHost.bootstrap(scopes, { aggregateId: threadId });
  server = http.createServer((req,res) => {
    if (req.url === '/release-stream') { releaseStream?.(); res.writeHead(204); res.end(); return; }
    if (req.url === '/') { res.writeHead(200, {'content-type':'text/html'}); res.end('<main id="runtime-slot"></main>'); return; }
    if (req.url === '/bundle.js') { res.writeHead(200, {'content-type':'text/javascript'}); res.end(buildResult.outputFiles[0].contents); return; }
    const upstream = http.request(new URL(req.url, base), { method:req.method, headers:req.headers }, response => { res.writeHead(response.statusCode, response.headers); res.flushHeaders(); if (pauseEffect && req.url.startsWith('/v1/harness/streams/')) { response.pause(); releaseStream = () => response.pipe(res); }
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
  browser = await chromium.launch({headless:true}); const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async config => { const { mount } = await import('/bundle.js'); window.runtime = mount(config); await window.runtime.panel.open(); }, { bearer, environmentId, threadId, schemaSHA256 });
  await page.getByLabel('Texto do comando durável').fill('efeito real web');
  await page.getByRole('button', {name:'Enviar comando'}).click();
  if (incompatible) {
    await page.getByRole('status').getByText('ERR_INCOMPATIBLE').waitFor({timeout:30000});
    assert.equal(await page.evaluate(() => window.runtime.client.state.lastSeq), 0);
  } else if (pauseEffect) {
    await page.getByText(/Aceito/).waitFor({timeout:30000});
    assert.equal(await page.locator('[data-completed="true"]').count(), 0);
    await page.evaluate(() => fetch('/release-stream', { method: 'POST' }));
  } else {
    await page.getByText(/Concluído/).waitFor({timeout:30000});
    assert.equal(await page.locator('[data-completed="true"]').count(), 1);
  }
  await page.evaluate(() => window.runtime.client.close());
  console.log(incompatible ? 'Chromium: versão incompatível recusada sem aplicar frame' : pauseEffect ? 'Chromium: receipt aceito antes da confirmação do efeito' : 'Chromium: bootstrap scoped, painel, dispatch e efeito real verificados');
} finally {
  await browser?.close(); if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  bootstrap?.close(); if (child.exitCode === null) { const exited = once(child,'exit'); child.kill('SIGTERM'); await exited; }
  await rm(tmp,{recursive:true,force:true});
}
