import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import {
  lstat,
  mkdir,
  readFile,
  realpath,
  rename,
  unlink,
  writeFile
} from 'node:fs/promises';
import path from 'node:path';

export const SOLUTION_SCHEMA_VERSION = 'pockettrace.pocketwiki_solution.v1';
export const DEFAULT_MAX_REQUEST_BYTES = 8 * 1024 * 1024;
export const MAX_MARKDOWN_BYTES = 5 * 1024 * 1024;

const SOLUTION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const REPLICABILITY_LEVELS = new Set(['R0', 'R1', 'R2', 'R3']);
const PUBLISH_MODES = new Set(['ai_enriched', 'deterministic_only']);
const solutionLocks = new Map();

export async function handleSolutionPut(req, res, options) {
  const {
    solutionId,
    reference,
    writeToken,
    maxRequestBytes = DEFAULT_MAX_REQUEST_BYTES,
    verifyIndexed
  } = options;

  if (reference.readonly) {
    return sendJson(res, 403, errorPayload('write_disabled', 'A base de referência está em modo somente leitura.'));
  }
  if (!reference.available) {
    return sendJson(res, 404, errorPayload('reference_unavailable', 'A base de referência configurada não está disponível.'));
  }
  if (!writeToken) {
    return sendJson(res, 503, errorPayload('write_unavailable', 'A credencial de escrita não está configurada no servidor.'));
  }
  if (!validBearer(req.headers.authorization, writeToken)) {
    return sendJson(res, 401, errorPayload('unauthorized', 'Credencial de escrita ausente ou inválida.'));
  }
  if (!isJsonContentType(req.headers['content-type'])) {
    return sendJson(res, 415, errorPayload('unsupported_media_type', 'Content-Type deve ser application/json.'));
  }
  if (!SOLUTION_ID_PATTERN.test(solutionId)) {
    return sendJson(res, 400, errorPayload('invalid_request', 'solution_id inválido no path.'));
  }

  const idempotencyKey = singleHeader(req.headers['idempotency-key']);
  if (!idempotencyKey) {
    return sendJson(res, 400, errorPayload('invalid_request', 'Idempotency-Key é obrigatório.'));
  }

  let payload;
  try {
    payload = await readJsonBody(req, maxRequestBytes);
  } catch (error) {
    if (error.code === 'payload_too_large') {
      return sendJson(res, 413, errorPayload('payload_too_large', `O payload excede o limite de ${maxRequestBytes} bytes.`));
    }
    return sendJson(res, 400, errorPayload('invalid_request', 'O corpo precisa ser JSON UTF-8 válido.'));
  }

  if (!isPlainObject(payload) || payload.solution_id !== solutionId) {
    return sendJson(res, 400, errorPayload('invalid_request', 'solution_id do path e do JSON precisam ser iguais.'));
  }

  const validationError = validateSolution(payload);
  if (validationError) {
    return sendJson(res, 422, errorPayload('schema_validation_failed', validationError));
  }

  const expectedIdempotencyKey = `${solutionId}:${payload.document_version}`;
  if (idempotencyKey !== expectedIdempotencyKey) {
    return sendJson(res, 400, errorPayload('invalid_request', 'Idempotency-Key não corresponde à solução e versão do documento.'));
  }

  if (computeOutputHash(payload) !== payload.output_hash) {
    return sendJson(res, 422, errorPayload('output_hash_mismatch', 'output_hash não corresponde ao documento canônico recebido.'));
  }

  try {
    const result = await ingestSolution({
      root: reference.path,
      solutionId,
      payload,
      idempotencyKey,
      ifMatch: singleHeader(req.headers['if-match']),
      verifyIndexed
    });
    return sendJson(res, result.status, result.body, { ETag: result.etag });
  } catch (error) {
    if (error instanceof IngestionError) {
      return sendJson(res, error.status, error.body, error.headers);
    }
    return sendJson(res, 500, errorPayload('write_failed', 'Não foi possível persistir e indexar a solução.'));
  }
}

export async function ingestSolution({
  root,
  solutionId,
  payload,
  idempotencyKey,
  ifMatch,
  verifyIndexed = verifyPersistedDocument
}) {
  return withSolutionLock(`${root}\0${solutionId}`, async () => {
    let paths;
    try {
      paths = await prepareSafePaths(root, solutionId, idempotencyKey);
    } catch {
      throw writeFailure();
    }

    const requestHash = sha256(Buffer.from(canonicalJSONStringify(payload), 'utf8'));
    const existingDocument = await readOptionalFile(paths.document).catch(() => { throw writeFailure(); });
    const currentRevision = existingDocument ? revisionFor(existingDocument) : null;
    const existingRecord = await readIdempotencyRecord(paths.idempotency).catch(() => { throw writeFailure(); });

    if (existingRecord) {
      if (existingRecord.request_hash !== requestHash) {
        throw conflictError(
          409,
          'idempotency_key_reused',
          'A chave de idempotência já foi usada com outro payload.',
          solutionId,
          currentRevision
        );
      }
      return {
        status: existingRecord.status,
        etag: existingRecord.etag,
        body: existingRecord.body,
        replayed: true
      };
    }

    if (!existingDocument && ifMatch) {
      throw conflictError(
        412,
        'remote_revision_mismatch',
        'If-Match não corresponde à revisão atual.',
        solutionId,
        null
      );
    }
    if (existingDocument && !ifMatch) {
      throw conflictError(
        409,
        'remote_conflict',
        'A solução já existe; informe a revisão remota para atualizar.',
        solutionId,
        currentRevision
      );
    }
    if (existingDocument && ifMatch !== currentRevision) {
      throw conflictError(
        412,
        'remote_revision_mismatch',
        'If-Match não corresponde à revisão atual.',
        solutionId,
        currentRevision
      );
    }

    const document = Buffer.from(renderMarkdownDocument(payload), 'utf8');
    const etag = revisionFor(document);
    const status = existingDocument ? 200 : 201;
    const body = {
      remote_id: solutionId,
      remote_revision: etag,
      message: existingDocument ? 'updated' : 'created'
    };
    const record = Buffer.from(`${JSON.stringify({
      version: 1,
      idempotency_key: idempotencyKey,
      request_hash: requestHash,
      status,
      etag,
      body,
      stored_at: new Date().toISOString()
    })}\n`, 'utf8');

    await commitDocumentAndIdempotency({
      paths,
      document,
      record,
      previousDocument: existingDocument,
      verifyIndexed
    });

    return { status, etag, body, replayed: false };
  });
}

export function validateSolution(payload) {
  if (payload.schema_version !== SOLUTION_SCHEMA_VERSION) return 'schema_version não suportado.';
  if (!boundedNonEmptyString(payload.generator_version, 200)) return 'generator_version inválido.';
  if (!SHA256_PATTERN.test(payload.input_hash || '')) return 'input_hash inválido.';
  if (!SHA256_PATTERN.test(payload.output_hash || '')) return 'output_hash inválido.';
  if (!SOLUTION_ID_PATTERN.test(payload.solution_id || '')) return 'solution_id inválido.';
  if (!boundedNonEmptyString(payload.document_version, 200)) return 'document_version inválido.';
  if (!boundedNonEmptyString(payload.trace_or_context_id, 200)) return 'trace_or_context_id inválido.';
  if (!boundedNonEmptyString(payload.title, 500)) return 'title inválido.';
  if (!boundedNonEmptyString(payload.summary, 4_000)) return 'summary inválido.';
  if (typeof payload.body_markdown !== 'string' || payload.body_markdown.length === 0) return 'body_markdown inválido.';
  if (Buffer.byteLength(payload.body_markdown, 'utf8') > MAX_MARKDOWN_BYTES) return 'body_markdown excede 5 MiB.';
  if (payload.category !== null && (typeof payload.category !== 'string' || codePointLength(payload.category) > 200)) {
    return 'category inválida.';
  }
  if (!Array.isArray(payload.tags) || payload.tags.length > 50 || payload.tags.some(tag => typeof tag !== 'string' || codePointLength(tag) > 80)) {
    return 'tags inválidas.';
  }
  if (!REPLICABILITY_LEVELS.has(payload.replicability_level)) return 'replicability_level inválido.';
  if (typeof payload.mvp5_candidate !== 'boolean') return 'mvp5_candidate inválido.';
  if (!Array.isArray(payload.source_hashes) || payload.source_hashes.length === 0) return 'source_hashes inválido.';
  for (const source of payload.source_hashes) {
    if (!isPlainObject(source) ||
        !nonEmptyString(source.path) ||
        !nonEmptyString(source.artifact_type) ||
        !nonEmptyString(source.schema_version) ||
        !SHA256_PATTERN.test(source.sha256 || '')) {
      return 'source_hashes contém referência inválida.';
    }
  }
  if (!PUBLISH_MODES.has(payload.publish_mode)) return 'publish_mode inválido.';
  return null;
}

export function computeOutputHash(payload) {
  return sha256(Buffer.from(canonicalJSONStringify({ ...payload, output_hash: '' }), 'utf8'));
}

export function canonicalJSONStringify(value) {
  return JSON.stringify(sortCanonical(value));
}

export function renderMarkdownDocument(payload) {
  const metadata = {
    schema_version: payload.schema_version,
    generator_version: payload.generator_version,
    input_hash: payload.input_hash,
    output_hash: payload.output_hash,
    solution_id: payload.solution_id,
    document_version: payload.document_version,
    trace_or_context_id: payload.trace_or_context_id,
    title: payload.title,
    summary: payload.summary,
    category: payload.category,
    tags: payload.tags,
    replicability_level: payload.replicability_level,
    mvp5_candidate: payload.mvp5_candidate,
    source_hashes: payload.source_hashes,
    publish_mode: payload.publish_mode
  };
  const frontmatter = Object.entries(metadata)
    .map(([key, value]) => `${key}: ${JSON.stringify(value)}`)
    .join('\n');
  const markdown = payload.body_markdown.endsWith('\n') ? payload.body_markdown : `${payload.body_markdown}\n`;
  return `---\n${frontmatter}\n---\n\n${markdown}`;
}

async function prepareSafePaths(root, solutionId, idempotencyKey) {
  const rootPath = await realpath(root);
  const solutions = await ensureSafeDirectory(rootPath, 'solutions');
  const state = await ensureSafeDirectory(rootPath, '.pocketwiki');
  const idempotency = await ensureSafeDirectory(state, 'solution-idempotency');
  const document = path.join(solutions, `${solutionId}.md`);
  const idempotencyFile = path.join(idempotency, `${sha256(Buffer.from(idempotencyKey, 'utf8'))}.json`);
  await rejectSymlink(document);
  await rejectSymlink(idempotencyFile);
  return { document, idempotency: idempotencyFile };
}

async function ensureSafeDirectory(parent, name) {
  const directory = path.join(parent, name);
  try {
    await assertSafeDirectory(directory);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await mkdir(directory, { mode: 0o700 }).catch(mkdirError => {
      if (mkdirError.code !== 'EEXIST') throw mkdirError;
    });
    await assertSafeDirectory(directory);
  }
  const canonicalParent = await realpath(parent);
  const canonicalDirectory = await realpath(directory);
  if (!isWithin(canonicalParent, canonicalDirectory)) throw new Error('directory_escape');
  return canonicalDirectory;
}

async function assertSafeDirectory(directory) {
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('unsafe_directory');
}

async function rejectSymlink(file) {
  try {
    const info = await lstat(file);
    if (info.isSymbolicLink() || !info.isFile()) throw new Error('unsafe_target');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

async function commitDocumentAndIdempotency({ paths, document, record, previousDocument, verifyIndexed }) {
  const documentTemp = `${paths.document}.tmp-${randomUUID()}`;
  const recordTemp = `${paths.idempotency}.tmp-${randomUUID()}`;
  let documentCommitted = false;
  let recordCommitted = false;
  try {
    await writeFile(documentTemp, document, { flag: 'wx', mode: 0o600 });
    await writeFile(recordTemp, record, { flag: 'wx', mode: 0o600 });
    await assertSafeDirectory(path.dirname(paths.document));
    await assertSafeDirectory(path.dirname(paths.idempotency));
    await rename(documentTemp, paths.document);
    documentCommitted = true;
    await verifyIndexed(paths.document, document);
    await rename(recordTemp, paths.idempotency);
    recordCommitted = true;
    await verifyIdempotencyRecord(paths.idempotency, record);
  } catch {
    if (recordCommitted) await unlink(paths.idempotency).catch(() => {});
    if (documentCommitted) await restoreDocument(paths.document, previousDocument).catch(() => {});
    await Promise.allSettled([unlink(documentTemp), unlink(recordTemp)]);
    throw writeFailure();
  }
}

async function restoreDocument(target, previousDocument) {
  if (!previousDocument) return unlink(target);
  const temp = `${target}.rollback-${randomUUID()}`;
  await writeFile(temp, previousDocument, { flag: 'wx', mode: 0o600 });
  await rename(temp, target);
}

async function verifyPersistedDocument(file, expected) {
  const actual = await readFile(file);
  if (!actual.equals(expected)) throw new Error('index_verification_failed');
}

async function verifyIdempotencyRecord(file, expected) {
  const actual = await readFile(file);
  if (!actual.equals(expected)) throw new Error('idempotency_verification_failed');
}

async function readOptionalFile(file) {
  try {
    return await readFile(file);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function readIdempotencyRecord(file) {
  const raw = await readOptionalFile(file);
  if (!raw) return null;
  const parsed = JSON.parse(raw.toString('utf8'));
  if (!isPlainObject(parsed) || parsed.version !== 1 || !parsed.request_hash || !parsed.etag || !isPlainObject(parsed.body)) {
    throw new Error('invalid_idempotency_record');
  }
  return parsed;
}

async function readJsonBody(req, maxBytes) {
  const declaredLength = Number(singleHeader(req.headers['content-length']));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    req.resume?.();
    throw codedError('payload_too_large');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maxBytes) throw codedError('payload_too_large');
    chunks.push(buffer);
  }
  const raw = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
  if (!raw) throw codedError('invalid_json');
  return JSON.parse(raw);
}

function validBearer(header, expectedToken) {
  if (typeof header !== 'string') return false;
  const match = /^Bearer ([^\s]+)$/.exec(header);
  if (!match) return false;
  const supplied = createHash('sha256').update(match[1], 'utf8').digest();
  const expected = createHash('sha256').update(expectedToken, 'utf8').digest();
  return timingSafeEqual(supplied, expected);
}

function isJsonContentType(value) {
  return typeof value === 'string' && /^application\/json(?:\s*;|$)/i.test(value);
}

function singleHeader(value) {
  if (Array.isArray(value)) return value.length === 1 ? value[0] : '';
  return typeof value === 'string' ? value : '';
}

function revisionFor(bytes) {
  return `"sha256:${sha256(bytes)}"`;
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sortCanonical(value) {
  if (Array.isArray(value)) return value.map(sortCanonical);
  if (!isPlainObject(value)) return value;
  return Object.keys(value).sort().reduce((result, key) => {
    result[key] = sortCanonical(value[key]);
    return result;
  }, {});
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype;
}

function boundedNonEmptyString(value, max) {
  return nonEmptyString(value) && codePointLength(value) <= max;
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function codePointLength(value) {
  return [...value].length;
}

function isWithin(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function conflictError(status, error, message, solutionId, revision) {
  const body = {
    remote_id: solutionId,
    remote_revision: revision,
    error,
    message
  };
  const headers = revision ? { ETag: revision } : {};
  return new IngestionError(status, body, headers);
}

function writeFailure() {
  return new IngestionError(500, errorPayload('write_failed', 'Não foi possível persistir e indexar a solução.'));
}

function errorPayload(error, message) {
  return { error, message };
}

function codedError(code) {
  return Object.assign(new Error(code), { code });
}

function sendJson(res, status, body, extraHeaders = {}) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(status, {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': payload.length,
    'Cache-Control': 'no-store',
    ...extraHeaders
  });
  res.end(payload);
}

async function withSolutionLock(key, operation) {
  const previous = solutionLocks.get(key) || Promise.resolve();
  let release;
  const current = new Promise(resolve => { release = resolve; });
  solutionLocks.set(key, current);
  await previous;
  try {
    return await operation();
  } finally {
    release();
    if (solutionLocks.get(key) === current) solutionLocks.delete(key);
  }
}

class IngestionError extends Error {
  constructor(status, body, headers = {}) {
    super(body.error);
    this.status = status;
    this.body = body;
    this.headers = headers;
  }
}
