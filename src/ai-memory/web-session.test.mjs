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
    if (url === '/api/ai-memory/recall') return { ok:true, json:async () => ({ context:'nota do ai-memory' }) };
    throw new Error('offline');
  });
  vm.runInContext('state.appConfig = { aiMemoryConfigured:true }', offline.context);
  offline.input.value = 'Pergunta';
  await vm.runInContext('askAi()', offline.context);
  assert.match(offline.requests[0], /nota do ai-memory/);
  const pending = JSON.parse(storage.getItem('pocketwiki:ai-hook-outbox-v1'));
  assert.deepEqual(pending.map(item => item.event), ['session-start', 'user-prompt-submit', 'assistant-response', 'stop']);
  assert(pending.every(item => /^[A-Za-z0-9_-]{1,64}$/.test(item.ingest_key)));

  const online = browser(storage, async (url, options) => {
    assert.equal(url, '/api/ai-memory/capture');
    const events = JSON.parse(options.body).events;
    return { ok:true, json:async () => ({ accepted_keys:events.map(item => item.ingest_key) }) };
  });
  vm.runInContext('state.appConfig = { aiMemoryConfigured:true }', online.context);
  await vm.runInContext('drainAiHookOutbox()', online.context);
  assert.equal(JSON.parse(storage.getItem('pocketwiki:ai-hook-outbox-v1')).length, 0);
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
