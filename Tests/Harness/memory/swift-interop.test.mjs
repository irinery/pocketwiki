import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import { spawn, fork } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { MemoryHarnessService } from '../../../src/harness/memory/service.mjs';

const executable = process.env.SWIFT_MEMORY_BINARY;
const environment = '10000000-0000-4000-8000-000000000001';
const project = '20000000-0000-4000-8000-000000000001';
const thread = '30000000-0000-4000-8000-000000000001';
const auth = { principal_id:'50000000-0000-4000-8000-000000000001', environment_id:environment,
  aggregate_id:project, thread_id:thread, scopes:['context.read', 'memory.write', 'memory.personal.read'] };
const namespace = { environment_id:environment, project_id:project, thread_id:thread, schema_version:2, note_revision:0 };
const next = (child) => new Promise((resolve, reject) => { child.once('message', resolve); child.once('error', reject); });

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'memory-interop-'));
  t.after(() => rm(root, { recursive:true, force:true }));
  return { root, service:new MemoryHarnessService({ root, policy:async () => true, association:async () => true }) };
}

test('JS e Swift leem a mesma nota, CAS e journal de eventos', { skip:!executable }, async (t) => {
  const { root, service } = await fixture(t);
  await service.notePut(auth, { namespace, content:'node', expected_revision:0 });
  await service.captureScoped(auth, { namespace, events:[{ event:'user-prompt-submit',
    session_id:'40000000-0000-4000-8000-000000000001', ingest_key:'interop', prompt:'postgres beta' }] });
  const expected = await service.recallScoped(auth, { environment_id:environment, project_id:project,
    thread_id:thread, question:'postgres beta', include_personal_note:false });
  const child = spawn(executable, ['--interop', root], { stdio:['ignore', 'pipe', 'inherit'] });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stdout.on('data', (data) => { output += data; });
  const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  assert.equal(code, 0); assert.deepEqual(JSON.parse(output), expected);
  assert.deepEqual(await service.noteGet(auth, { namespace }), { content:'swift', revision:2 });
  const events = await service.eventsSince(auth, { namespace, after_seq:0 });
  assert.deepEqual(events.map((event) => event.value.content), ['node', 'swift']);
});

test('SIGKILL do escritor Swift libera lock SQLite para writer Node', { skip:!executable }, async (t) => {
  const { root, service } = await fixture(t);
  await service.noteGet(auth, { namespace });
  const database = path.join(root, 'v2', environment, 'projects', project, '.harness-writer.sqlite3');
  const holder = spawn(executable, ['--hold-lock', database], { stdio:['ignore', 'pipe', 'inherit'] });
  t.after(() => holder.kill('SIGKILL'));
  await new Promise((resolve, reject) => { holder.stdout.once('data', resolve); holder.once('error', reject); });
  const writer = fork(new URL('./cas-worker.mjs', import.meta.url), [root, 'after'], { stdio:['ignore', 'ignore', 'inherit', 'ipc'] });
  t.after(() => writer.kill('SIGKILL'));
  await next(writer);
  let outcome; writer.once('message', (message) => { outcome = message; }); writer.send('go');
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.equal(outcome, undefined);
  holder.kill('SIGKILL');
  await new Promise((resolve) => holder.once('exit', resolve));
  if (outcome === undefined) await new Promise((resolve) => writer.once('message', resolve));
  assert.equal(outcome, 'ok');
});

test('cursor gerado em Node continua a mesma página em Swift', { skip:!executable }, async (t) => {
  const { root, service } = await fixture(t);
  for (let index = 1; index <= 3; index++) {
    const threadID = `30000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    await service.notePut({ ...auth, thread_id:threadID }, {
      namespace:{ ...namespace, thread_id:threadID }, content:`note ${index}`, expected_revision:0
    });
  }
  const projectScope = { environment_id:environment, project_id:project, schema_version:2, note_revision:0 };
  const projectAuth = { ...auth, thread_id:undefined };
  const first = await service.snapshot(projectAuth, { namespace:projectScope, page_size:1 });
  assert.ok(first.next_cursor);
  const expected = await service.snapshot(projectAuth, { namespace:projectScope, page_size:1, cursor:first.next_cursor });
  const child = spawn(executable, ['--page', root, first.next_cursor], { stdio:['ignore', 'pipe', 'inherit'] });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stdout.on('data', (data) => { output += data; });
  const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  assert.equal(code, 0); assert.deepEqual(JSON.parse(output), expected);
});

test('cursor gerado em Swift continua a mesma página em Node', { skip:!executable }, async (t) => {
  const { root, service } = await fixture(t);
  for (let index = 1; index <= 3; index++) {
    const threadID = `30000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    await service.notePut({ ...auth, thread_id:threadID }, {
      namespace:{ ...namespace, thread_id:threadID }, content:`note ${index}`, expected_revision:0
    });
  }
  const child = spawn(executable, ['--first-page', root], { stdio:['ignore', 'pipe', 'inherit'] });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stdout.on('data', (data) => { output += data; });
  const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  assert.equal(code, 0);
  const first = JSON.parse(output);
  assert.ok(first.next_cursor);
  const projectScope = { environment_id:environment, project_id:project, schema_version:2, note_revision:0 };
  const second = await service.snapshot({ ...auth, thread_id:undefined }, { namespace:projectScope, cursor:first.next_cursor });
  assert.equal(second.snapshot_id, first.snapshot_id);
  assert.equal(second.notes[0].namespace.thread_id, '30000000-0000-4000-8000-000000000002');
});

test('export/import redigido funciona nos dois sentidos JS e Swift', { skip:!executable }, async (t) => {
  const source = await fixture(t);
  const nodeDestination = await fixture(t);
  const swiftDestination = await fixture(t);
  await source.service.captureScoped(auth, { namespace, events:[{ event:'user-prompt-submit',
    session_id:'40000000-0000-4000-8000-000000000009', ingest_key:'portable',
    prompt:'postgres password="example phrase" em /etc/private/config C:\\Temp\\example' }] });
  await source.service.notePut(auth, { namespace, content:'nota /tmp/private', expected_revision:0 });
  async function run(mode, root, input) {
    const child = spawn(executable, [mode, root], { stdio:['pipe', 'pipe', 'inherit'] });
    let output = '';
    child.stdout.setEncoding('utf8'); child.stdout.on('data', (data) => { output += data; });
    child.stdin.end(input);
    const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
    assert.equal(code, 0); return JSON.parse(output);
  }
  const exportedSwift = await run('--export', source.root);
  assert.doesNotMatch(exportedSwift.content, /example phrase|\/etc\/private|\/tmp\/private|C:\\\\Temp/);
  assert.equal((await nodeDestination.service.importNamespace(auth, { namespace, content:exportedSwift.content })).imported_count, 1);
  const exportedNode = await source.service.exportNamespace(auth, { namespace, include_personal_note:true });
  assert.equal((await run('--import', swiftDestination.root, exportedNode.content)).imported_count, 1);
  assert.equal((await swiftDestination.service.noteGet(auth, { namespace })).content, 'nota [redacted path]');
  const recalled = await swiftDestination.service.recallScoped(auth, { environment_id:environment, project_id:project,
    thread_id:thread, question:'postgres', include_personal_note:false });
  assert.equal(recalled.hits.length, 1);
});

test('Swift e Node bloqueiam os três journals existentes sem autoridade e preservam bytes', { skip:!executable }, async (t) => {
  for (const kind of ['capture', 'note', 'import']) {
    await t.test(kind, async (subtest) => {
      const { root, service } = await fixture(subtest);
      await service.notePut(auth, { namespace, content:'committed', expected_revision:0 });
      const folder = path.join(root, 'v2', environment, 'projects', project);
      const journal = path.join(folder, `.${kind}-intent.json`);
      const bytes = JSON.stringify({ journal_version:1, principal_id:auth.principal_id, receipt_id:thread,
        command_id:project, environment_id:environment, operation:'memory.import',
        records:[], content:'unapproved replay', authorized:true });
      await writeFile(journal, bytes);
      const child = spawn(executable, ['--assert-recovery-blocked', root], { stdio:['ignore', 'pipe', 'inherit'] });
      let output = '';
      child.stdout.setEncoding('utf8'); child.stdout.on('data', data => { output += data; });
      const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
      assert.equal(code, 0); assert.equal(output.trim(), 'blocked');
      assert.equal(await readFile(journal, 'utf8'), bytes);
      await assert.rejects(service.noteGet(auth, { namespace }), { code:'ERR_MEMORY_UNAVAILABLE' });
      assert.equal(await readFile(path.join(folder, '.notes', thread, 'MEMORY.md'), 'utf8'), 'committed');
    });
  }
});

test('corpus de redação produz textos equivalentes em JS e Swift', { skip:!executable }, async (t) => {
  const { root, service } = await fixture(t);
  const corpus = JSON.parse(await readFile(new URL('./export-redaction-corpus.json', import.meta.url), 'utf8'));
  for (const [index, item] of corpus.entries()) {
    await service.captureScoped(auth, { namespace, events:[{ event:'user-prompt-submit',
      session_id:`40000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
      ingest_key:`corpus-${index}`, prompt:item.text }] });
  }
  await service.notePut(auth, { namespace, content:corpus.map((item) => item.text).join('\n'), expected_revision:0 });
  const expected = JSON.parse((await service.exportNamespace(auth, { namespace, include_personal_note:true })).content);
  const child = spawn(executable, ['--export', root], { stdio:['ignore', 'pipe', 'inherit'] });
  let output = '';
  child.stdout.setEncoding('utf8'); child.stdout.on('data', (data) => { output += data; });
  const code = await new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  assert.equal(code, 0);
  const actual = JSON.parse(JSON.parse(output).content);
  assert.deepEqual(actual, expected);
});
