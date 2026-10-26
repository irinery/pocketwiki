import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { PocketMemoryStore } from './store.mjs';

const SESSION = '0ce8f327-c7d3-4d5a-a633-8e46d6b922cf';
const events = [
  { event:'session-start', session_id:SESSION, ingest_key:'start_1' },
  { event:'user-prompt-submit', session_id:SESSION, ingest_key:'prompt_1', prompt:'Como configurar VLAN IoT no MikroTik?' },
  { event:'assistant-response', session_id:SESSION, ingest_key:'answer_1', message:'A VLAN IoT usa tag 30 no bridge.', provider_id:'lmstudio', model_id:'qwen' }
];

async function withStore(run) {
  const root = await mkdtemp(path.join(tmpdir(), 'pocketwiki-memory-'));
  try { await run(new PocketMemoryStore(root), root); }
  finally { await rm(root, { recursive:true, force:true }); }
}

test('captura registros portaveis, persiste e ignora reenvio do mesmo evento', async () => {
  await withStore(async (store, root) => {
    assert.deepEqual(await store.capture(events), events.map(item => item.ingest_key));
    assert.deepEqual(await store.capture(events), events.map(item => item.ingest_key));
    const record = JSON.parse(await readFile(path.join(root, 'captures', `session-${SESSION}.json`), 'utf8'));
    assert.equal(record.events.length, 3);
    assert.deepEqual(record.messages.map(item => item.role), ['user', 'assistant']);
    assert.equal(record.messages[1].model_id, 'qwen');
    assert.equal((await new PocketMemoryStore(root).recall('VLAN IoT')).hits[0].id, SESSION);
    assert.match((await store.recall('VLAN IoT')).context, /tag 30/);
  });
});

test('nota MEMORY.md e conversa local entram no contexto sem provider', async () => {
  await withStore(async (store, root) => {
    await store.writeNote('# Preferencias\nResponder em portugues.');
    await writeFile(path.join(root, `session-${SESSION}.json`), JSON.stringify({
      id:SESSION, created_at:'2026-10-20T00:00:00Z', updated_at:'2026-10-20T00:00:00Z',
      messages:[{ role:'user', content:'Zabbix monitorando PowerEdge' }, { role:'assistant', content:'Use IPMI para o iDRAC' }]
    }));
    const result = await store.recall('PowerEdge');
    assert.match(result.context, /Responder em portugues/);
    assert.match(result.context, /IPMI para o iDRAC/);
    assert.equal(result.hits[0].source, 'local');
    assert.equal(await new PocketMemoryStore(root).readNote(), '# Preferencias\nResponder em portugues.');
  });
});

test('lotes paralelos preservam todos os eventos e entradas invalidas sao rejeitadas', async () => {
  await withStore(async (store, root) => {
    await Promise.all(Array.from({ length:20 }, (_, index) => store.capture([{
      event:'user-prompt-submit', session_id:SESSION, ingest_key:`parallel_${index}`, prompt:`Pergunta ${index} sobre rede`
    }])));
    const record = JSON.parse(await readFile(path.join(root, 'captures', `session-${SESSION}.json`), 'utf8'));
    assert.equal(record.events.length, 20);
    assert.throws(() => store.capture([{ ...events[1], session_id:'../../etc/passwd' }]), /invalid_event/);
    assert.throws(() => store.capture([{ ...events[2], message:'' }]), /invalid_event/);
    await assert.rejects(store.writeNote('x'.repeat(17_000)), /invalid_memory_note/);
  });
});
