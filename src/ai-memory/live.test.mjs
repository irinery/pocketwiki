import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createServer as createTCPServer } from 'node:net';
import { once } from 'node:events';
import { createAIMemoryConfiguration, recallMemory, captureMemoryEvents } from './client.mjs';

const execFileAsync = promisify(execFile);
const image = process.env.AI_MEMORY_TEST_IMAGE || 'akitaonrails/ai-memory:3.2.2';

async function docker(...args) {
  const { stdout } = await execFileAsync('docker', args, { timeout: 180_000, maxBuffer: 1024 * 1024 });
  return stdout.trim();
}

async function freePort() {
  const server = createTCPServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  server.close();
  await once(server, 'close');
  return port;
}

async function waitUntilReady(baseURL) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const response = await fetch(`${baseURL}/healthz`, { signal:AbortSignal.timeout(1000) });
      if (response.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  throw new Error('ai-memory não respondeu em /healthz');
}

async function rpc(baseURL, authToken, method, params) {
  const response = await fetch(`${baseURL}/mcp`, {
    method:'POST',
    headers:{
      'Content-Type':'application/json',
      Accept:'application/json, text/event-stream',
      Authorization:`Bearer ${authToken}`
    },
    body:JSON.stringify({ jsonrpc:'2.0', id:randomUUID(), method, params }),
    signal:AbortSignal.timeout(5000)
  });
  assert.equal(response.status, 200, `MCP ${method} respondeu HTTP ${response.status}`);
  const envelope = await response.json();
  assert.equal(envelope.error, undefined, JSON.stringify(envelope.error));
  assert.notEqual(envelope.result?.isError, true, JSON.stringify(envelope.result));
  return envelope.result;
}

async function tool(baseURL, authToken, name, args) {
  const result = await rpc(baseURL, authToken, 'tools/call', { name, arguments:args });
  return result.structuredContent || JSON.parse(result.content.find(item => item.type === 'text').text);
}

test('contrato oficial MCP + hooks com servidor ai-memory real', { timeout:240_000 }, async () => {
  const port = await freePort();
  const baseURL = `http://127.0.0.1:${port}`;
  const container = `pocketwiki-ai-memory-test-${randomUUID().slice(0, 8)}`;
  const authToken = randomBytes(24).toString('hex');
  const scope = { workspace:'validation', project:`pocketwiki-${randomUUID().slice(0, 8)}` };
  const marker = `giraffeplume${randomBytes(5).toString('hex')}`;
  try {
    await docker('run', '--rm', '-d', '--name', container,
      '-p', `127.0.0.1:${port}:49374`, '-e', `AI_MEMORY_AUTH_TOKEN=${authToken}`, image);
    await waitUntilReady(baseURL);

    const denied = await fetch(`${baseURL}/mcp`, {
      method:'POST', headers:{ 'Content-Type':'application/json', Accept:'application/json' },
      body:JSON.stringify({ jsonrpc:'2.0', id:1, method:'tools/list', params:{} })
    });
    assert([401, 403].includes(denied.status), `MCP sem token respondeu ${denied.status}`);

    // Mesmo handshake e ferramentas dos exemplos em docs/programmatic-memory.md.
    const initialized = await rpc(baseURL, authToken, 'initialize', {
      protocolVersion:'2024-11-05', capabilities:{}, clientInfo:{ name:'pocketwiki-validation', version:'1.0' }
    });
    assert(initialized.protocolVersion);
    const listed = await rpc(baseURL, authToken, 'tools/list', {});
    for (const name of ['memory_write_page', 'memory_query', 'memory_read_page']) {
      assert(listed.tools.some(item => item.name === name), `MCP sem ${name}`);
    }

    const path = `notes/${marker}.md`;
    const body = `# Política ${marker}\nPreserve o mesmo ingest_key ao reenviar eventos.`;
    const written = await tool(baseURL, authToken, 'memory_write_page', { ...scope, path, body });
    assert.equal(written.path, path);
    const queried = await tool(baseURL, authToken, 'memory_query', { ...scope, query:marker });
    assert(queried.hits.some(hit => hit.path === path));
    const read = await tool(baseURL, authToken, 'memory_read_page', { ...scope, path });
    assert.equal(read.body, body);

    const config = createAIMemoryConfiguration({ serverURL:baseURL, ...scope, authToken });
    assert.match(await recallMemory(config, marker), /Preserve o mesmo ingest_key/);
    const otherProject = createAIMemoryConfiguration({
      serverURL:baseURL, workspace:scope.workspace, project:`other-${randomUUID().slice(0, 8)}`, authToken
    });
    await assert.rejects(recallMemory(otherProject, marker));

    // Mesmo envelope ordenado e ingest_key estável de docs/external-lifecycle.md.
    const session_id = randomUUID();
    const events = [
      { event:'session-start' },
      { event:'user-prompt-submit', prompt:`A VLAN do ${marker} é 207.` },
      { event:'assistant-response', message:'Entendido: VLAN 207 para IoT.' },
      { event:'stop' },
      { event:'session-end' }
    ].map((item, index) => ({
      ...item, session_id, ingest_key:`pw_live_${session_id.replaceAll('-', '')}_${index}`
    }));
    assert.deepEqual(await captureMemoryEvents(config, events, '/tmp/pocketwiki-validation'),
      events.map(item => item.ingest_key));

    const replayURL = new URLSearchParams({
      event:events[0].event, agent:'other', ...scope, extension:'pocketwiki.web',
      source_event:events[0].event, ingest_key:events[0].ingest_key
    });
    const replay = await fetch(`${baseURL}/hook/batch`, {
      method:'POST',
      headers:{ 'Content-Type':'application/json', Authorization:`Bearer ${authToken}` },
      body:JSON.stringify([{ url:`/hook?${replayURL}`, body:{ session_id, cwd:'/tmp/pocketwiki-validation' } }])
    });
    assert.equal(replay.status, 200);
    const replayReceipt = await replay.json();
    assert.deepEqual(replayReceipt.accepted_indices ?? Array.from({ length:replayReceipt.accepted }, (_, index) => index), [0]);
    assert.equal(replayReceipt.results?.[0]?.outcome, 'replayed');
    assert.deepEqual(await captureMemoryEvents(config, events, '/tmp/pocketwiki-validation'),
      events.map(item => item.ingest_key));

    let sessionPage;
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        sessionPage = await tool(baseURL, authToken, 'memory_read_page', {
          ...scope, path:`sessions/${session_id}.md`
        });
        break;
      } catch {
        await new Promise(resolve => setTimeout(resolve, 200));
      }
    }
    assert(sessionPage, 'hook/batch não gerou a página da sessão');
    assert.match(sessionPage.body, new RegExp(marker));
    assert.match(sessionPage.body, /\*\*observations:\*\* 5/);
  } finally {
    await docker('rm', '-f', container).catch(() => {});
  }
});
