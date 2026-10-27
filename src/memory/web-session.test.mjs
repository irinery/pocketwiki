import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('../../wiki-cockpit.html', import.meta.url), 'utf8');
const script = html.match(/<script>\s*([\s\S]*?)<\/script>/)?.[1].split('// Events')[0];
assert(script, 'cockpit script ausente');

function browser(storage, fetchImpl) {
  const input = { value: '' };
  const requests = [];
  const context = vm.createContext({
    localStorage: storage,
    console,
    Date,
    Map,
    Set,
    URL,
    Blob,
    fetch: fetchImpl,
    setTimeout,
    clearTimeout,
    location: { protocol: 'http:' },
    document: { querySelector: selector => selector === '#ai-question' ? input : null },
    window: {},
    globalThis: {}
  });
  vm.runInContext(script, context);
  vm.runInContext(`
    renderAiPanel = () => {};
    saveAiSettings = () => {};
    fetchPocketKernel = async text => {
      requests.push(text);
      return { ok:true, json:async () => ({ answer:'Resposta ' + requests.length }) };
    };
  `, context);
  context.requests = requests;
  return { context, input, requests };
}

test('restaura conversa e mantém o histórico ao trocar provider/modelo', async () => {
  const data = new Map();
  const storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
    key: index => [...data.keys()][index],
    get length() { return data.size; }
  };
  const first = browser(storage);
  first.input.value = 'Primeira pergunta';
  await vm.runInContext('askAi()', first.context);
  assert.equal(JSON.parse(storage.getItem('pocketwiki:ai-session-v1')).messages.length, 2);

  const second = browser(storage);
  vm.runInContext("state.ai.providerMethod = 'lmstudio'; state.ai.model = 'modelo-local'", second.context);
  second.input.value = 'Continua';
  await vm.runInContext('askAi()', second.context);
  assert.match(second.requests[0], /Primeira pergunta/);
  assert.match(second.requests[0], /Resposta 1/);
  const active = JSON.parse(storage.getItem('pocketwiki:ai-session-v1'));
  assert.equal(active.messages.length, 4);
  assert.match(active.created_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.equal(active.messages[3].provider_id, 'lmstudio');
  assert.equal(active.messages[3].model_id, 'modelo-local');

  vm.runInContext('newAiConversation()', second.context);
  assert(storage.getItem(`pocketwiki:ai-archive:${active.id}`));
  assert.equal(JSON.parse(storage.getItem('pocketwiki:ai-session-v1')).messages.length, 0);
});

test('importa sessão JSON do app Mac, retoma arquivo e continua com outro modelo', async () => {
  const data = new Map();
  const storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
    key: index => [...data.keys()][index],
    get length() { return data.size; }
  };
  const page = browser(storage);
  const imported = {
    schema_version: 1,
    id: '0ce8f327-c7d3-4d5a-a633-8e46d6b922cf',
    created_at: '2026-10-26T13:00:00Z',
    updated_at: '2026-10-26T13:01:00Z',
    messages: [
      { role:'user', content:'Como funciona a VLAN 207?', created_at:'2026-10-26T13:00:00Z', provider_id:null, model_id:null },
      { role:'assistant', content:'A VLAN 207 isola IoT.', created_at:'2026-10-26T13:01:00Z', provider_id:'openai', model_id:'gpt-5.5' }
    ]
  };
  page.context.imported = imported;
  assert.equal(vm.runInContext('importAiSessionsData(imported)', page.context), 1);
  assert.equal(vm.runInContext('importAiSessionsData(imported)', page.context), 0);
  assert.equal(vm.runInContext('resumeAiSession(imported.id)', page.context), true);
  assert.equal(vm.runInContext('state.ai.messages.length', page.context), 2);
  vm.runInContext("state.ai.providerMethod = 'lmstudio'; state.ai.model = 'modelo-local'", page.context);
  page.input.value = 'E as câmeras?';
  await vm.runInContext('askAi()', page.context);
  assert.match(page.requests[0], /A VLAN 207 isola IoT/);
  const active = JSON.parse(storage.getItem('pocketwiki:ai-session-v1'));
  assert.equal(active.messages[3].model_id, 'modelo-local');
  assert.equal(active.id, imported.id);
});

test('mantém eventos pendentes e reenvia após recarregar', async () => {
  const data = new Map();
  const storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
    key: index => [...data.keys()][index],
    get length() { return data.size; }
  };
  const offline = browser(storage, async url => {
    if (url === '/api/memory/recall') return { ok:true, json:async () => ({ context:'nota da memoria PocketWiki' }) };
    throw new Error('offline');
  });
  vm.runInContext("state.appConfig = { memoryConfigured:true }; state.ai.memoryWebToken = 'browser-secret-123456789'", offline.context);
  offline.input.value = 'Pergunta';
  await vm.runInContext('askAi()', offline.context);
  assert.match(offline.requests[0], /nota da memoria PocketWiki/);
  const pending = JSON.parse(storage.getItem('pocketwiki:memory-outbox-v1'));
  assert.deepEqual(pending.map(item => item.event), ['session-start', 'user-prompt-submit', 'assistant-response', 'stop']);
  assert.equal(pending[2].model_id, vm.runInContext('state.ai.model', offline.context));
  assert(pending.every(item => /^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key)));

  const online = browser(storage, async (url, options) => {
    assert.equal(url, '/api/memory/capture');
    assert.equal(options.headers.Authorization, 'Bearer browser-secret-123456789');
    const events = JSON.parse(options.body).events;
    return { ok:true, json:async () => ({ accepted_keys:events.map(item => item.ingest_key) }) };
  });
  vm.runInContext("state.appConfig = { memoryConfigured:true }; state.ai.memoryWebToken = 'browser-secret-123456789'", online.context);
  await vm.runInContext('drainMemoryOutbox()', online.context);
  assert.equal(JSON.parse(storage.getItem('pocketwiki:memory-outbox-v1')).length, 0);
});

test('preserva o registro completo além do limite de renderização', () => {
  const data = new Map();
  const storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
    key: index => [...data.keys()][index],
    get length() { return data.size; }
  };
  const page = browser(storage);
  vm.runInContext(`
    state.ai.messages = Array.from({length:81}, (_, index) => ({
      id:newAiId(), role:'user', content:'Mensagem ' + index, createdAt:aiTimestamp()
    }));
    persistAiSession();
  `, page.context);
  assert.equal(JSON.parse(storage.getItem('pocketwiki:ai-session-v1')).messages.length, 81);
  const reloaded = browser(storage);
  assert.equal(vm.runInContext('state.ai.messages.length', reloaded.context), 81);
});

test('limita o evento enviado sem cortar a transcricao local', () => {
  const data = new Map();
  const storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
    key: index => [...data.keys()][index],
    get length() { return data.size; }
  };
  const page = browser(storage);
  vm.runInContext("state.appConfig = { memoryConfigured:true }; state.ai.messages.push({id:newAiId(), role:'user', content:'x'.repeat(9000), createdAt:aiTimestamp()}); persistAiSession(); queueMemoryCapture('user-prompt-submit', newAiId(), {prompt:'x'.repeat(9000)})", page.context);
  const pending = JSON.parse(storage.getItem('pocketwiki:memory-outbox-v1'));
  assert.equal(pending[0].prompt.length, 8000);
  assert.equal(JSON.parse(storage.getItem('pocketwiki:ai-session-v1')).messages[0].content.length, 9000);
});
