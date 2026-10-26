import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createAIMemoryConfiguration, recallMemory, captureMemoryEvents } from './client.mjs';

test('consulta MCP e captura hooks com escopo e autenticação no servidor', async () => {
  const calls = [];
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString());
    calls.push({ path: request.url, auth: request.headers.authorization, body });
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/base/mcp') {
      const tool = body.params?.name;
      const data = tool === 'memory_query'
        ? { hits: [{ path: 'notes/example.md', title: 'Exemplo', snippet: 'resumo' }] }
        : { body: '# Memória real' };
      response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: tool
        ? { content: [{ type: 'text', text: JSON.stringify(data) }] }
        : { protocolVersion: '2024-11-05' } }));
    } else {
      response.end(JSON.stringify({ accepted_indices: [0, 1] }));
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const config = createAIMemoryConfiguration({
      serverURL: `http://127.0.0.1:${server.address().port}/base`,
      workspace: 'team', project: 'wiki', authToken: 'secret'
    });
    assert.equal(config.endpoint.pathname, '/base/mcp');
    assert.match(await recallMemory(config, 'onde está?'), /# Memória real/);
    const sessionId = '0ce8f327-c7d3-4d5a-a633-8e46d6b922cf';
    const accepted = await captureMemoryEvents(config, [
      { event: 'session-start', session_id: sessionId, ingest_key: 'start_1' },
      { event: 'user-prompt-submit', session_id: sessionId, ingest_key: 'prompt_1', prompt: 'onde está?' }
    ], '/wiki');
    assert.deepEqual(accepted, ['start_1', 'prompt_1']);
    assert.equal(calls.length, 4);
    assert(calls.every(call => call.auth === 'Bearer secret'));
    assert.equal(calls[1].body.params.arguments.workspace, 'team');
    assert.equal(calls[1].body.params.arguments.project, 'wiki');
    assert.equal(calls[3].path, '/base/hook/batch');
    assert.match(calls[3].body[1].url, /extension=pocketwiki.web/);
    assert.equal(calls[3].body[1].body.cwd, '/wiki');
    assert.equal(calls[3].body[1].body.prompt, 'onde está?');
  } finally {
    server.close();
    await once(server, 'close');
  }
});

test('recusa eventos malformados antes de enviar', async () => {
  const config = createAIMemoryConfiguration({ serverURL: 'http://127.0.0.1:49374', workspace: 'w', project: 'p' });
  await assert.rejects(captureMemoryEvents(config, [{ event: 'unknown', session_id: 'x', ingest_key: 'bad key' }], '/wiki'), /invalid ai-memory event/);
});

test('não trata HTTP 200 com erro JSON-RPC ou isError como memória válida', async () => {
  let failure = 'rpc';
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString());
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify(body.method === 'initialize'
      ? { jsonrpc:'2.0', id:body.id, result:{ protocolVersion:'2024-11-05' } }
      : failure === 'rpc'
        ? { jsonrpc:'2.0', id:body.id, error:{ code:-32602, message:'escopo inválido' } }
        : { jsonrpc:'2.0', id:body.id, result:{ isError:true, content:[{ type:'text', text:'negado' }] } }));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const config = createAIMemoryConfiguration({
      serverURL:`http://127.0.0.1:${server.address().port}`, workspace:'team', project:'wiki'
    });
    await assert.rejects(recallMemory(config, 'teste'), /escopo inválido/);
    failure = 'tool';
    await assert.rejects(recallMemory(config, 'teste'), /memory_query failed/);
  } finally {
    server.close();
    await once(server, 'close');
  }
});

test('preserva confirmações parciais de /hook/batch para reenviar só pendências', async () => {
  const replies = [
    { status:429, body:{ accepted_indices:[1, 3], failed_index:0 } },
    { status:429, body:{ accepted:2, failed_index:2 } },
    { status:429, body:{ accepted_indices:[], failed_index:0 } }
  ];
  const server = createServer(async (_request, response) => {
    const reply = replies.shift();
    response.writeHead(reply.status, { 'Content-Type':'application/json' });
    response.end(JSON.stringify(reply.body));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const config = createAIMemoryConfiguration({
      serverURL:`http://127.0.0.1:${server.address().port}`, workspace:'team', project:'wiki'
    });
    const session_id = '0ce8f327-c7d3-4d5a-a633-8e46d6b922cf';
    const events = ['session-start', 'user-prompt-submit', 'stop', 'session-end'].map((event, index) => ({
      event, session_id, ingest_key:`event_${index}`
    }));
    assert.deepEqual(await captureMemoryEvents(config, events, '/wiki'), ['event_1', 'event_3']);
    assert.deepEqual(await captureMemoryEvents(config, events.slice(0, 2), '/wiki'), ['event_0', 'event_1']);
    await assert.rejects(captureMemoryEvents(config, events, '/wiki'), /HTTP 429/);
  } finally {
    server.close();
    await once(server, 'close');
  }
});
