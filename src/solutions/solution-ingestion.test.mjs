import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';

import {
  computeOutputHash,
  handleSolutionPut
} from './solution-ingestion.mjs';

const TOKEN = 'write-token-for-tests';
const roots = [];

test.after(async () => {
  await Promise.allSettled(roots.map(root => rm(root, { recursive: true, force: true })));
});

test('PW-SOL-01 criação válida retorna 201, indexa Markdown e não persiste token', async () => {
  const root = await tempRoot();
  const payload = solution();
  const response = await invoke(root, payload);

  assert.equal(response.status, 201);
  assert.equal(response.body.message, 'created');
  assert.equal(response.headers.ETag, response.body.remote_revision);
  assert.match(response.headers.ETag, /^"sha256:[a-f0-9]{64}"$/);

  const document = await readFile(path.join(root, 'solutions', `${payload.solution_id}.md`), 'utf8');
  assert.match(document, /title: "Configurar observabilidade"/);
  assert.match(document, /# Configurar observabilidade/);
  assert.doesNotMatch(await readTree(root), new RegExp(TOKEN));
});

test('PW-SOL-02 mesma chave e payload retorna o resultado gravado sem segunda escrita', async () => {
  const root = await tempRoot();
  const payload = solution();
  const first = await invoke(root, payload);
  const before = await readFile(path.join(root, 'solutions', `${payload.solution_id}.md`));
  const replay = await invoke(root, payload);
  const after = await readFile(path.join(root, 'solutions', `${payload.solution_id}.md`));

  assert.equal(replay.status, first.status);
  assert.deepEqual(replay.body, first.body);
  assert.deepEqual(after, before);
  assert.equal((await readdir(path.join(root, '.pocketwiki', 'solution-idempotency'))).length, 1);
});

test('PW-SOL-03 mesma chave com payload diferente retorna 409', async () => {
  const root = await tempRoot();
  const initial = solution();
  await invoke(root, initial);
  const changed = solution({ summary: 'Outro conteúdo com a mesma versão.' });
  const response = await invoke(root, changed);

  assert.equal(response.status, 409);
  assert.equal(response.body.error, 'idempotency_key_reused');
});

test('PW-SOL-04 solução existente sem If-Match retorna 409 e mantém bytes', async () => {
  const root = await tempRoot();
  const initial = solution();
  await invoke(root, initial);
  const file = path.join(root, 'solutions', `${initial.solution_id}.md`);
  const before = await readFile(file);
  const response = await invoke(root, solution({ document_version: 'doc_v2', summary: 'Versão 2.' }));

  assert.equal(response.status, 409);
  assert.equal(response.body.error, 'remote_conflict');
  assert.deepEqual(await readFile(file), before);
});

test('PW-SOL-05 update com revisão correta retorna 200 e nova revisão', async () => {
  const root = await tempRoot();
  const created = await invoke(root, solution());
  const updated = await invoke(
    root,
    solution({ document_version: 'doc_v2', body_markdown: '# Configurar observabilidade\n\nVersão nova.' }),
    { ifMatch: created.body.remote_revision }
  );

  assert.equal(updated.status, 200);
  assert.equal(updated.body.message, 'updated');
  assert.notEqual(updated.body.remote_revision, created.body.remote_revision);
});

test('PW-SOL-06 update com revisão antiga retorna 412 e mantém bytes', async () => {
  const root = await tempRoot();
  const created = await invoke(root, solution());
  const updated = await invoke(root, solution({ document_version: 'doc_v2', summary: 'Versão 2.' }), {
    ifMatch: created.body.remote_revision
  });
  const file = path.join(root, 'solutions', 'solution_demo.md');
  const before = await readFile(file);
  const stale = await invoke(root, solution({ document_version: 'doc_v3', summary: 'Versão 3.' }), {
    ifMatch: created.body.remote_revision
  });

  assert.equal(stale.status, 412);
  assert.equal(stale.body.error, 'remote_revision_mismatch');
  assert.equal(stale.body.remote_revision, updated.body.remote_revision);
  assert.deepEqual(await readFile(file), before);
});

test('PW-SOL-07 edição manual altera a revisão remota observada', async () => {
  const root = await tempRoot();
  const created = await invoke(root, solution());
  const file = path.join(root, 'solutions', 'solution_demo.md');
  await writeFile(file, `${await readFile(file, 'utf8')}\nEdição manual.\n`, 'utf8');
  const response = await invoke(root, solution({ document_version: 'doc_v2', summary: 'Versão 2.' }), {
    ifMatch: created.body.remote_revision
  });

  assert.equal(response.status, 412);
  assert.notEqual(response.body.remote_revision, created.body.remote_revision);
});

test('PW-SOL-08 bearer ausente ou inválido retorna 401 sem detalhar divergência', async () => {
  const root = await tempRoot();
  const missing = await invoke(root, solution(), { authorization: null });
  const invalid = await invoke(root, solution(), { authorization: 'Bearer token-errado' });

  assert.equal(missing.status, 401);
  assert.equal(invalid.status, 401);
  assert.deepEqual(missing.body, invalid.body);
  assert.doesNotMatch(JSON.stringify(invalid.body), /token-errado|write-token/);
});

test('PW-SOL-09 base read-only retorna 403', async () => {
  const root = await tempRoot();
  const response = await invoke(root, solution(), { readonly: true });

  assert.equal(response.status, 403);
  assert.equal(response.body.error, 'write_disabled');
});

test('PW-SOL-10 traversal e symlink não escrevem fora da raiz', async () => {
  const root = await tempRoot();
  const outside = await tempRoot();
  const traversal = await invoke(root, solution({ solution_id: '../escape' }), { solutionId: '../escape' });
  assert.equal(traversal.status, 400);

  await symlink(outside, path.join(root, 'solutions'));
  const escaped = await invoke(root, solution());
  assert.equal(escaped.status, 500);
  assert.deepEqual(await readdir(outside), []);
});

test('PW-SOL-11 falha de indexação faz rollback e não confirma idempotência', async () => {
  const root = await tempRoot();
  const response = await invoke(root, solution(), {
    verifyIndexed: async () => { throw new Error('index failed'); }
  });

  assert.equal(response.status, 500);
  assert.equal(response.body.error, 'write_failed');
  await assert.rejects(readFile(path.join(root, 'solutions', 'solution_demo.md')), { code: 'ENOENT' });
  assert.deepEqual(await readdir(path.join(root, '.pocketwiki', 'solution-idempotency')), []);
});

test('PW-SOL-12 payload acima do limite retorna 413 antes de acumular o corpo', async () => {
  const root = await tempRoot();
  const response = await invoke(root, solution(), { contentLength: 9 * 1024 * 1024 });

  assert.equal(response.status, 413);
  assert.equal(response.body.error, 'payload_too_large');
});

test('PW-SOL-13 response e logs não contêm token nem Markdown integral', async () => {
  const root = await tempRoot();
  const payload = solution({ body_markdown: '# SEGREDO-MARKDOWN-INTEGRAL' });
  const logs = [];
  const originalWarn = console.warn;
  console.warn = (...args) => logs.push(args.join(' '));
  try {
    const response = await invoke(root, payload, { authorization: 'Bearer inválido' });
    assert.equal(response.status, 401);
    const observable = `${JSON.stringify(response.body)}\n${logs.join('\n')}`;
    assert.doesNotMatch(observable, /SEGREDO-MARKDOWN-INTEGRAL|Bearer inválido|write-token-for-tests/);
  } finally {
    console.warn = originalWarn;
  }
});

test('PW-SOL-14 idempotência continua funcionando a partir do store em disco', async () => {
  const root = await tempRoot();
  const payload = solution();
  const first = await invoke(root, payload);
  const replay = await invoke(root, payload);

  assert.equal(replay.status, 201);
  assert.deepEqual(replay.body, first.body);
});

test('PW-SOL-15 output_hash divergente retorna erro específico 422', async () => {
  const root = await tempRoot();
  const payload = solution();
  payload.output_hash = 'f'.repeat(64);
  const response = await invoke(root, payload);

  assert.equal(response.status, 422);
  assert.equal(response.body.error, 'output_hash_mismatch');
});

test('PW-SOL-16 servidor sem token falha fechado com 503', async () => {
  const root = await tempRoot();
  const response = await invoke(root, solution(), { writeToken: '' });

  assert.equal(response.status, 503);
  assert.equal(response.body.error, 'write_unavailable');
});

test('PW-SOL-17 Content-Type diferente de JSON retorna 415', async () => {
  const root = await tempRoot();
  const response = await invoke(root, solution(), { contentType: 'text/plain' });

  assert.equal(response.status, 415);
  assert.equal(response.body.error, 'unsupported_media_type');
});

test('PW-SOL-18 JSON fora do schema retorna 422 sem ecoar conteúdo', async () => {
  const root = await tempRoot();
  const payload = solution();
  payload.tags = Array.from({ length: 51 }, (_, index) => `tag-${index}`);
  payload.output_hash = computeOutputHash(payload);
  const response = await invoke(root, payload);

  assert.equal(response.status, 422);
  assert.equal(response.body.error, 'schema_validation_failed');
  assert.doesNotMatch(JSON.stringify(response.body), /tag-50/);
});

function solution(overrides = {}) {
  const payload = {
    schema_version: 'pockettrace.pocketwiki_solution.v1',
    generator_version: 'pockettrace.processor.v1',
    input_hash: 'a'.repeat(64),
    output_hash: '',
    solution_id: 'solution_demo',
    document_version: 'doc_v1',
    trace_or_context_id: 'pt_example',
    title: 'Configurar observabilidade',
    summary: 'Runbook revisado para configurar observabilidade.',
    body_markdown: '# Configurar observabilidade\n\nConteúdo revisado.',
    category: 'infraestrutura',
    tags: ['observabilidade', 'macos'],
    replicability_level: 'R2',
    mvp5_candidate: false,
    source_hashes: [{
      path: 'ai/runs/example/validated_output.json',
      artifact_type: 'ai_validated_output_json',
      schema_version: 'pockettrace.ai_validated_enrichment.v1',
      sha256: 'c'.repeat(64)
    }],
    publish_mode: 'ai_enriched',
    ...overrides
  };
  payload.output_hash = computeOutputHash(payload);
  return payload;
}

async function invoke(root, payload, options = {}) {
  const raw = Buffer.from(JSON.stringify(payload), 'utf8');
  const req = Readable.from([raw]);
  req.headers = {
    authorization: options.authorization === null ? undefined : (options.authorization || `Bearer ${TOKEN}`),
    'content-type': options.contentType || 'application/json',
    'content-length': String(options.contentLength ?? raw.length),
    'idempotency-key': `${payload.solution_id}:${payload.document_version}`,
    'if-match': options.ifMatch
  };
  const response = captureResponse();
  await handleSolutionPut(req, response.res, {
    solutionId: options.solutionId || payload.solution_id,
    reference: {
      path: root,
      available: true,
      readonly: options.readonly || false
    },
    writeToken: options.writeToken === undefined ? TOKEN : options.writeToken,
    verifyIndexed: options.verifyIndexed
  });
  return response.value();
}

function captureResponse() {
  let status;
  let headers;
  let body = Buffer.alloc(0);
  return {
    res: {
      writeHead(nextStatus, nextHeaders) {
        status = nextStatus;
        headers = nextHeaders;
      },
      end(chunk) {
        if (chunk) body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      }
    },
    value() {
      return { status, headers, body: JSON.parse(body.toString('utf8')) };
    }
  };
}

async function tempRoot() {
  const root = await mkdtemp(path.join(tmpdir(), 'pocketwiki-solutions-'));
  roots.push(root);
  return root;
}

async function readTree(root) {
  const contents = [];
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.isFile()) contents.push(await readFile(full, 'utf8'));
    }
  }
  await walk(root);
  return contents.join('\n');
}
