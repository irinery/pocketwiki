import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile, symlink, readdir, mkdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { MemoryHarnessService } from '../../../src/harness/memory/service.mjs';
import { PocketMemoryStore } from '../../../src/memory/store.mjs';

const environment = '10000000-0000-4000-8000-000000000001';
const project = '20000000-0000-4000-8000-000000000001';
const thread = '30000000-0000-4000-8000-000000000001';
const principal = '50000000-0000-4000-8000-000000000001';
const namespace = { environment_id:environment, project_id:project, thread_id:thread, schema_version:2, note_revision:0 };
const identity = { principal_id:principal, environment_id:environment, aggregate_id:project,
  thread_id:thread, scopes:['memory.write', 'context.read', 'memory.personal.read'] };
const makeService = root => new MemoryHarnessService({ root, policy:async () => true, association:async () => true });

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'memory-recovery-disabled-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  const service = makeService(root);
  await service.notePut(identity, { namespace, content:'committed note', expected_revision:0 });
  const folder = path.join(root, 'v2', environment, 'projects', project);
  return { root, folder, service };
}

for (const kind of ['capture', 'note', 'import']) {
  test(`journal ${kind} preservado; identidade e receipt declarados não autorizam replay`, async t => {
    const { root, folder } = await fixture(t);
    const journal = path.join(folder, `.${kind}-intent.json`);
    const states = {
      '.memory-notes.json':await readFile(path.join(folder, '.memory-notes.json')),
      [path.join('.notes', thread, 'MEMORY.md')]:await readFile(path.join(folder, '.notes', thread, 'MEMORY.md'))
    };
    for (const bytes of ['null', '{broken', JSON.stringify({ journal_version:1, principal_id:principal,
      receipt_id:thread, command_id:project, environment_id:environment, operation:'memory.import',
      command_sha256:'a'.repeat(64), payload_sha256:'b'.repeat(64), scopes:['memory.write'],
      records:[], events:[], ledger:{ sequence:0, accepted_keys:{} }, content:'unapproved', authorized:true })]) {
      await writeFile(journal, bytes);
      for (const auth of [identity, { ...identity, principal_id:'50000000-0000-4000-8000-000000000002' }]) {
        const reopened = makeService(root);
        await assert.rejects(reopened.noteGet(auth, { namespace }), { code:'ERR_MEMORY_UNAVAILABLE' });
        await assert.rejects(reopened.notePut(auth, { namespace, content:'overwrite', expected_revision:1 }), { code:'ERR_MEMORY_UNAVAILABLE' });
        await assert.rejects(reopened.recallScoped(auth, { environment_id:environment, project_id:project,
          thread_id:thread, question:'unapproved', include_personal_note:false }), { code:'ERR_MEMORY_UNAVAILABLE' });
        assert.equal(await readFile(journal, 'utf8'), bytes);
      }
      const store = new PocketMemoryStore(root).namespace(namespace);
      await assert.rejects(store.recoverCapture(), { code:'ERR_MEMORY_UNAVAILABLE' });
      await assert.rejects(store.notePutCAS('bypass facade', 1, namespace), { code:'ERR_MEMORY_UNAVAILABLE' });
      for (const [name, before] of Object.entries(states)) assert.deepEqual(await readFile(path.join(folder, name)), before);
    }
  });
}

test('journal em symlink ou diretório é bloqueado sem ler nem modificar o alvo', async t => {
  const { folder, service } = await fixture(t);
  const journal = path.join(folder, '.capture-intent.json');
  const target = path.join(folder, 'private-target');
  await writeFile(target, 'never recover or log');
  await symlink(target, journal);
  await assert.rejects(service.noteGet(identity, { namespace }), { code:'ERR_MEMORY_UNAVAILABLE' });
  assert.equal(await readFile(target, 'utf8'), 'never recover or log');
  await rm(journal);
  await symlink(path.join(folder, 'missing-target'), journal);
  await assert.rejects(service.noteGet(identity, { namespace }), { code:'ERR_MEMORY_UNAVAILABLE' });
  await rm(journal);
  await mkdir(journal);
  await assert.rejects(service.noteGet(identity, { namespace }), { code:'ERR_MEMORY_UNAVAILABLE' });
});

test('commit ativo legítimo continua funcionando; reabertura sem journal mantém CAS e deduplicação', async t => {
  const { root, folder, service } = await fixture(t);
  const event = { event:'user-prompt-submit', session_id:'40000000-0000-4000-8000-000000000001',
    ingest_key:'committed', prompt:'postgres committed' };
  await service.captureScoped(identity, { namespace, events:[event] });
  const reopened = makeService(root);
  assert.deepEqual(await reopened.noteGet(identity, { namespace }), { content:'committed note', revision:1 });
  assert.deepEqual(await reopened.captureScoped(identity, { namespace, events:[event] }), { accepted_keys:['committed'] });
  await reopened.notePut(identity, { namespace, content:'second', expected_revision:1 });
  await assert.rejects(reopened.notePut(identity, { namespace, content:'stale', expected_revision:1 }), { code:'ERR_CONFLICT' });
  assert.equal((await reopened.recallScoped(identity, { environment_id:environment, project_id:project,
    thread_id:thread, question:'postgres committed', include_personal_note:false })).hits.length, 1);
  assert.equal((await readdir(folder)).some(name => name.endsWith('-intent.json')), false);
});
