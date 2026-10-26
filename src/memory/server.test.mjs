import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer as createTCPServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const TOKEN = 'internal-memory-token-123456';
const SESSION = '0ce8f327-c7d3-4d5a-a633-8e46d6b922cf';
async function freePort() {
  const socket = createTCPServer();
  socket.listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  socket.close();
  await once(socket, 'close');
  return port;
}

async function startServer(root, port) {
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd:new URL('../..', import.meta.url),
    env:{ ...process.env, POCKETWIKI_PORT:String(port), POCKETWIKI_BIND_HOST:'127.0.0.1',
      POCKETWIKI_MDNS:'false', POCKETWIKI_REFERENCE_PATH:root, POCKETWIKI_ENV_PATH:path.join(root, '.env'),
      POCKETWIKI_MEMORY_PATH:path.join(root, 'memory'), POCKETWIKI_MEMORY_TOKEN:TOKEN },
    stdio:['ignore', 'pipe', 'pipe']
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  const base = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 100 && child.exitCode === null; attempt++) {
    try { if ((await fetch(`${base}/api/config`)).ok) return { child, base }; }
    catch {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  child.kill('SIGTERM');
  throw new Error(`servidor nao iniciou: ${output}`);
}

async function request(base, endpoint, method, body, token = TOKEN) {
  return fetch(`${base}/api/memory/${endpoint}`, {
    method, headers:{ ...(token ? { Authorization:`Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type':'application/json' }) },
    ...(body === undefined ? {} : { body:JSON.stringify(body) })
  });
}

test('API interna protege, persiste, consulta e reabre a mesma memoria', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'pocketwiki-memory-server-'));
  await writeFile(path.join(root, '.env'), '');
  const port = await freePort();
  let server;
  try {
    server = await startServer(root, port);
    const config = await (await fetch(`${server.base}/api/config`)).json();
    assert.equal(config.memoryConfigured, true);
    assert(!JSON.stringify(config).includes(TOKEN));
    assert.equal((await request(server.base, 'recall', 'POST', { question:'VLAN' }, '')).status, 401);
    assert.equal((await request(server.base, 'capture', 'POST', { events:[] })).status, 400);
    const batch = [{ event:'user-prompt-submit', session_id:SESSION, ingest_key:'web_prompt_1', prompt:'VLAN para IoT' },
      { event:'assistant-response', session_id:SESSION, ingest_key:'web_answer_1', message:'Use VLAN 30 no MikroTik', provider_id:'openai', model_id:'gpt' }];
    const capture = await request(server.base, 'capture', 'POST', { events:batch });
    assert.equal(capture.status, 200);
    assert.deepEqual((await capture.json()).accepted_keys, ['web_prompt_1', 'web_answer_1']);
    assert.equal((await request(server.base, 'capture', 'POST', { events:batch })).status, 200);
    assert.equal((await request(server.base, 'note', 'PUT', { content:'# Perfil\nInfra self-hosted.' })).status, 200);
    assert.equal((await (await request(server.base, 'note', 'GET')).json()).content, '# Perfil\nInfra self-hosted.');
    let recall = await request(server.base, 'recall', 'POST', { question:'VLAN MikroTik' });
    assert.equal(recall.status, 200);
    assert.match((await recall.json()).context, /VLAN 30/);
    assert.equal((await request(server.base, 'recall', 'POST', { question:'' })).status, 400);
    const record = JSON.parse(await readFile(path.join(root, 'memory', 'captures', `session-${SESSION}.json`), 'utf8'));
    assert.equal(record.messages.length, 2);
    server.child.kill('SIGTERM');
    await once(server.child, 'exit');
    server = await startServer(root, port);
    recall = await request(server.base, 'recall', 'POST', { question:'MikroTik' });
    assert.match((await recall.json()).context, /VLAN 30/);
  } finally {
    if (server?.child.exitCode === null) {
      server.child.kill('SIGTERM');
      await once(server.child, 'exit');
    }
    await rm(root, { recursive:true, force:true });
  }
});
