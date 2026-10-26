import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createServer as createTCPServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

async function freePort() {
  const server = createTCPServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  server.close();
  await once(server, 'close');
  return port;
}

test('proxy web consulta e captura com token apenas no servidor', async () => {
  const upstreamCalls = [];
  const upstream = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString());
    upstreamCalls.push({ auth: request.headers.authorization, path: request.url, body });
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/mcp') {
      const tool = body.params?.name;
      const value = tool === 'memory_query' ? { hits:[{ path:'notes/test.md', snippet:'teste' }] } : { body:'# Memória compartilhada' };
      response.end(JSON.stringify({ jsonrpc:'2.0', id:body.id, result: tool ? { content:[{ type:'text', text:JSON.stringify(value) }] } : {} }));
    } else {
      response.end(JSON.stringify({ accepted_indices:[0] }));
    }
  });
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  const port = await freePort();
  const reference = await mkdtemp(path.join(tmpdir(), 'pocketwiki-ai-memory-'));
  const envPath = path.join(reference, '.env');
  await writeFile(envPath, '');
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: new URL('../..', import.meta.url),
    env: {
      ...process.env,
      POCKETWIKI_PORT: String(port),
      POCKETWIKI_BIND_HOST: '127.0.0.1',
      POCKETWIKI_MDNS: 'false',
      POCKETWIKI_REFERENCE_PATH: reference,
      POCKETWIKI_ENV_PATH: envPath,
      AI_MEMORY_SERVER_URL: `http://127.0.0.1:${upstream.address().port}`,
      AI_MEMORY_WORKSPACE: 'team',
      AI_MEMORY_PROJECT: 'wiki',
      AI_MEMORY_AUTH_TOKEN: 'server-secret',
      AI_MEMORY_WEB_TOKEN: 'browser-secret-123456789'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let childOutput = '';
  child.stdout.on('data', chunk => { childOutput += chunk.toString(); });
  child.stderr.on('data', chunk => { childOutput += chunk.toString(); });
  try {
    const root = `http://127.0.0.1:${port}`;
    let config;
    for (let attempt = 0; attempt < 100 && child.exitCode === null; attempt++) {
      try {
        config = await (await fetch(`${root}/api/config`)).json();
        break;
      } catch {
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
    assert(config, `servidor PocketWiki não iniciou: ${childOutput}`);
    assert.equal(config.aiMemoryConfigured, true);
    assert(!JSON.stringify(config).includes('server-secret'));
    assert(!JSON.stringify(config).includes('browser-secret'));
    assert.equal((await fetch(`${root}/api/ai-memory/recall`, {
      method:'POST', headers:{ 'Content-Type':'application/json' }, body:JSON.stringify({ question:'teste' })
    })).status, 401);
    const recall = await fetch(`${root}/api/ai-memory/recall`, {
      method:'POST', headers:{ 'Content-Type':'application/json', Authorization:'Bearer browser-secret-123456789' }, body:JSON.stringify({ question:'teste' })
    });
    assert.equal(recall.status, 200);
    assert.match((await recall.json()).context, /Memória compartilhada/);
    const capture = await fetch(`${root}/api/ai-memory/capture`, {
      method:'POST', headers:{ 'Content-Type':'application/json', Authorization:'Bearer browser-secret-123456789' }, body:JSON.stringify({ events:[{
        event:'user-prompt-submit', session_id:'0ce8f327-c7d3-4d5a-a633-8e46d6b922cf', ingest_key:'web_event_1', prompt:'teste'
      }] })
    });
    assert.equal(capture.status, 200);
    assert.deepEqual((await capture.json()).accepted_keys, ['web_event_1']);
    assert(upstreamCalls.every(call => call.auth === 'Bearer server-secret'));
    assert.equal(upstreamCalls.at(-1).body[0].body.cwd, reference);
  } finally {
    child.kill('SIGTERM');
    if (child.exitCode === null) await once(child, 'exit');
    upstream.close();
    await once(upstream, 'close');
    await rm(reference, { recursive:true, force:true });
  }
});
