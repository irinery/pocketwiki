import { randomUUID } from 'node:crypto';

const EVENT_NAMES = new Set([
  'session-start', 'user-prompt-submit', 'assistant-response', 'stop', 'session-end'
]);

export function createAIMemoryConfiguration({ serverURL, workspace, project, authToken = '' }) {
  if (!serverURL?.trim() || !workspace?.trim() || !project?.trim()) return null;
  let endpoint;
  try {
    endpoint = new URL(serverURL.trim());
  } catch {
    return null;
  }
  if (!['http:', 'https:'].includes(endpoint.protocol) || !endpoint.hostname ||
      endpoint.username || endpoint.password || endpoint.search || endpoint.hash) return null;
  endpoint.pathname = `${endpoint.pathname.replace(/\/+$/, '').replace(/\/mcp$/, '')}/mcp`;
  return {
    endpoint,
    workspace: workspace.trim(),
    project: project.trim(),
    authToken: authToken.trim()
  };
}

function headers(config, accept = 'application/json') {
  return {
    'Content-Type': 'application/json',
    Accept: accept,
    ...(config.authToken ? { Authorization: `Bearer ${config.authToken}` } : {})
  };
}

async function postJSON(url, body, config, accept) {
  const response = await fetch(url, {
    method: 'POST',
    headers: headers(config, accept),
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(4000)
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(`ai-memory HTTP ${response.status}`);
  return payload;
}

async function rpc(config, method, params) {
  const payload = await postJSON(config.endpoint, {
    jsonrpc: '2.0',
    id: randomUUID(),
    method,
    params
  }, config, 'application/json, text/event-stream');
  if (payload?.error) throw new Error(payload.error.message || 'ai-memory JSON-RPC error');
  return payload;
}

async function callTool(config, name, args) {
  const payload = await rpc(config, 'tools/call', {
    name,
    arguments: { workspace: config.workspace, project: config.project, ...args }
  });
  const result = payload?.result;
  if (!result || result.isError) throw new Error(`ai-memory ${name} failed`);
  if (result.structuredContent) return result.structuredContent;
  const text = result.content?.find(item => typeof item?.text === 'string')?.text;
  if (!text) throw new Error(`ai-memory ${name} returned no JSON`);
  return JSON.parse(text);
}

export async function recallMemory(config, question) {
  await rpc(config, 'initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'pocketwiki-web', version: '1.0' }
  });
  const query = await callTool(config, 'memory_query', {
    query: String(question).slice(0, 500), limit: 3
  });
  let remaining = 5000;
  const blocks = [];
  for (const hit of (query.hits || []).slice(0, 3)) {
    if (remaining <= 0 || !hit?.path) break;
    let body;
    try {
      body = (await callTool(config, 'memory_read_page', { path: hit.path })).body;
    } catch {
      body = null;
    }
    const content = String(body || hit.snippet || '').replaceAll('<mark>', '').replaceAll('</mark>', '');
    const block = `Fonte ai-memory: ${hit.path}\nTitulo: ${hit.title || hit.path}\n${content}`.slice(0, remaining);
    blocks.push(block);
    remaining -= block.length;
  }
  return blocks.join('\n\n---\n\n');
}

export async function captureMemoryEvents(config, events, cwd) {
  if (!Array.isArray(events) || events.length < 1 || events.length > 32) {
    throw new Error('invalid event batch');
  }
  const batch = events.map(item => {
    if (!EVENT_NAMES.has(item?.event) ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(item.session_id || '') ||
        !/^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key || '')) {
      throw new Error('invalid ai-memory event');
    }
    const query = new URLSearchParams({
      event: item.event,
      agent: 'other',
      workspace: config.workspace,
      project: config.project,
      extension: 'pocketwiki.web',
      source_event: item.event,
      ingest_key: item.ingest_key
    });
    return {
      url: `/hook?${query}`,
      body: {
        session_id: item.session_id,
        cwd,
        ...(typeof item.prompt === 'string' ? { prompt: item.prompt.slice(0, 8000) } : {}),
        ...(typeof item.message === 'string' ? { message: item.message.slice(0, 8000) } : {})
      }
    };
  });
  const hookURL = new URL('hook/batch', config.endpoint);
  hookURL.pathname = config.endpoint.pathname.replace(/\/mcp$/, '/hook/batch');
  const result = await postJSON(hookURL, batch, config);
  const indices = Array.isArray(result.accepted_indices)
    ? result.accepted_indices
    : Array.from({ length: Math.min(Number(result.accepted) || 0, events.length) }, (_, index) => index);
  return indices.filter(index => Number.isInteger(index) && index >= 0 && index < events.length)
    .map(index => events[index].ingest_key);
}

