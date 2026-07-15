import { createHash } from 'node:crypto';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CURRENT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(CURRENT_DIR, '../..');
const DEFAULT_REFERENCE_PATH = path.join(REPO_ROOT, 'SKILL/wiki-reference');

export const RFC03_LIMITS = Object.freeze({
  maxQueryChars: 500,
  defaultSearchLimit: 8,
  maxSearchLimit: 50,
  maxDocumentIDChars: 128,
  maxDocumentBytes: 5 * 1024 * 1024,
  maxReturnedDocumentChars: 128_000,
  maxLinks: 200,
  toolTimeoutMs: 5_000
});

const ERROR_CODES = new Set([
  'ERR_VALIDATION',
  'ERR_FORBIDDEN',
  'ERR_TIMEOUT',
  'ERR_DEPENDENCY_UNAVAILABLE',
  'ERR_CONFLICT',
  'ERR_POLICY_DENIED',
  'ERR_RESOURCE_EXHAUSTED'
]);

export async function readPocketWikiEnv(envPath = path.join(REPO_ROOT, '.env')) {
  try {
    const raw = await readFile(envPath, 'utf8');
    const values = {};
    for (const line of raw.split(/\r?\n/)) {
      const clean = line.trim();
      if (!clean || clean.startsWith('#')) continue;
      const match = clean.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (!match) continue;
      values[match[1]] = unquoteEnvValue(match[2].trim());
    }
    return values;
  } catch (err) {
    if (err?.code === 'ENOENT') return {};
    throw err;
  }
}

export async function resolveWikiRoot({ root, env = process.env, envPath } = {}) {
  const fileValues = await readPocketWikiEnv(envPath);
  const configured = root ?? env.POCKETWIKI_REFERENCE_PATH ?? fileValues.POCKETWIKI_REFERENCE_PATH ?? DEFAULT_REFERENCE_PATH;
  return resolveConfiguredPath(configured);
}

export function createTypedError(code, message, traceID = '', details = {}) {
  const safeCode = ERROR_CODES.has(code) ? code : 'ERR_CONFLICT';
  return {
    ok: false,
    code: safeCode,
    message,
    trace_id: traceID || '',
    details: {
      field_errors: details.field_errors ?? [],
      dependency: details.dependency ?? '',
      resource_limit: details.resource_limit ?? ''
    }
  };
}

export async function searchWiki(root, input = {}) {
  const started = Date.now();
  const traceID = stringValue(input.trace_id);
  const query = stringValue(input.query).trim();
  const fieldErrors = [];

  if (!query) {
    fieldErrors.push({ field: 'query', message: 'obrigatorio' });
  } else if (query.length > RFC03_LIMITS.maxQueryChars) {
    fieldErrors.push({ field: 'query', message: `maximo de ${RFC03_LIMITS.maxQueryChars} caracteres` });
  }

  const limit = normalizeLimit(input.limit, fieldErrors);
  const includeDeprecated = Boolean(input.include_deprecated);

  if (fieldErrors.length > 0) {
    return createTypedError('ERR_VALIDATION', 'query invalida.', traceID, { field_errors: fieldErrors });
  }

  const index = await buildEvidenceIndex(root, traceID);
  const terms = tokenize(query);
  const results = [];

  for (const document of index.documents) {
    if (timedOut(started)) return timeoutError(traceID);
    if (!includeDeprecated && document.deprecated) continue;

    const score = scoreDocument(document, terms, query);
    if (score <= 0 && query !== '*') continue;

    results.push({
      document_id: document.document_id,
      title: document.title,
      status: document.status,
      trust: document.trust,
      source_type: document.source_type,
      score,
      snippet: makeSnippet(document, terms, query),
      deprecated: document.deprecated
    });
  }

  results.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));

  return {
    ok: true,
    trace_id: traceID,
    results: results.slice(0, limit)
  };
}

export async function getWikiDocument(root, input = {}) {
  const traceID = stringValue(input.trace_id);
  const documentID = stringValue(input.document_id).trim();
  const redactionMode = stringValue(input.redaction_mode || 'basic').trim().toLowerCase();
  const includeLinks = input.include_links !== false;
  const fieldErrors = [];

  if (!documentID) {
    fieldErrors.push({ field: 'document_id', message: 'obrigatorio' });
  } else if (documentID.length > RFC03_LIMITS.maxDocumentIDChars) {
    fieldErrors.push({ field: 'document_id', message: `maximo de ${RFC03_LIMITS.maxDocumentIDChars} caracteres` });
  } else if (!isSafeDocumentID(documentID)) {
    fieldErrors.push({ field: 'document_id', message: 'formato invalido' });
  }

  if (!['basic', 'none'].includes(redactionMode)) {
    fieldErrors.push({ field: 'redaction_mode', message: 'use basic' });
  }

  if (fieldErrors.length > 0) {
    return createTypedError('ERR_VALIDATION', 'document_id invalido.', traceID, { field_errors: fieldErrors });
  }

  if (redactionMode === 'none') {
    return createTypedError('ERR_POLICY_DENIED', 'redaction_mode=none nao e permitido para evidence server.', traceID, {
      field_errors: [{ field: 'redaction_mode', message: 'use basic' }]
    });
  }

  const index = await buildEvidenceIndex(root, traceID);
  const wanted = normalizeDocumentID(documentID);
  const document = index.documents.find(item => item.document_id === wanted || item.aliases.includes(wanted));

  if (!document) {
    return createTypedError('ERR_VALIDATION', 'documento inexistente.', traceID, {
      field_errors: [{ field: 'document_id', message: 'nao encontrado' }]
    });
  }

  if (document.size_bytes > RFC03_LIMITS.maxDocumentBytes || document.content.length > RFC03_LIMITS.maxReturnedDocumentChars) {
    return createTypedError('ERR_RESOURCE_EXHAUSTED', 'documento excede o limite de leitura MCP.', traceID, {
      resource_limit: `max_document_chars=${RFC03_LIMITS.maxReturnedDocumentChars}`
    });
  }

  return {
    ok: true,
    trace_id: traceID,
    document: {
      document_id: document.document_id,
      content: redactSensitiveContent(document.content),
      evidence_only: true,
      links: includeLinks ? document.links.map(formatLink).slice(0, RFC03_LIMITS.maxLinks) : [],
      meta: {
        document_id: document.document_id,
        title: document.title,
        path: document.path,
        status: document.status,
        trust: document.trust,
        source_type: document.source_type,
        version: document.version,
        etag: document.etag,
        deprecated: document.deprecated
      }
    }
  };
}

export async function buildEvidenceIndex(root, traceID = '') {
  const resolvedRoot = path.resolve(root || DEFAULT_REFERENCE_PATH);
  let rootStat;
  try {
    rootStat = await stat(resolvedRoot);
  } catch (err) {
    return unavailableIndexError(err, traceID, resolvedRoot);
  }
  if (!rootStat.isDirectory()) {
    throw createTypedError('ERR_DEPENDENCY_UNAVAILABLE', 'wiki root nao e diretorio.', traceID, { dependency: resolvedRoot });
  }

  const documents = [];
  await walkWiki(resolvedRoot, resolvedRoot, documents);
  return {
    root: resolvedRoot,
    documents: documents.sort((a, b) => a.path.localeCompare(b.path))
  };
}

async function walkWiki(root, current, documents) {
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    const absolute = path.join(current, entry.name);
    const relative = normalizeRelativePath(path.relative(root, absolute));

    if (entry.isDirectory()) {
      if (shouldSkipDirectory(relative, entry.name)) continue;
      await walkWiki(root, absolute, documents);
      continue;
    }

    if (!entry.isFile()) continue;
    if (!isMarkdownPath(relative) || isSensitivePath(relative)) continue;

    const info = await stat(absolute);
    if (info.size > RFC03_LIMITS.maxDocumentBytes) continue;
    const content = await readFile(absolute, 'utf8');
    documents.push(toEvidenceDocument(relative, content, info));
  }
}

function toEvidenceDocument(relativePath, content, info) {
  const frontmatter = parseFrontmatter(content);
  const body = stripFrontmatter(content);
  const documentID = pathToDocumentID(relativePath);
  const baseAlias = slugify(path.basename(removeWikiExtension(relativePath)));
  const title = cleanTitle(frontmatter.title) || firstHeading(body) || titleFromPath(relativePath);
  const status = normalizeEnum(frontmatter.status, ['validated', 'draft', 'candidate', 'archived', 'deprecated'], 'draft');
  const deprecated = parseBoolean(frontmatter.deprecated) || status === 'deprecated';
  const trust = normalizeEnum(frontmatter.trust, ['high', 'medium', 'low', 'unknown'], 'unknown');
  const sourceType = normalizeEnum(frontmatter.source_type || frontmatter.source, ['manual', 'imported', 'generated', 'external', 'unknown'], 'manual');
  const version = parsePositiveInteger(frontmatter.version, 1);
  const etag = weakETag(relativePath, content, info);
  const links = extractLinks(body);
  const searchable = [
    title,
    relativePath,
    frontmatter.summary || frontmatter.description || '',
    body,
    links.map(link => link.label || link.target).join(' ')
  ].join('\n');

  return {
    document_id: documentID,
    aliases: unique([documentID, baseAlias, slugify(title)]).filter(Boolean),
    title,
    path: relativePath,
    content,
    body,
    searchable,
    status,
    trust,
    source_type: sourceType,
    version,
    etag,
    deprecated,
    links,
    size_bytes: info.size,
    modified_at: info.mtime.toISOString()
  };
}

function scoreDocument(document, terms, query) {
  if (query === '*') return 1;
  const haystack = foldText(document.searchable);
  const title = foldText(document.title);
  const pathText = foldText(document.path);
  let score = 0;

  for (const term of terms) {
    if (!term) continue;
    if (title.includes(term)) score += 3;
    if (pathText.includes(term)) score += 1.5;
    score += Math.min(4, countOccurrences(haystack, term)) * 0.8;
  }

  if (foldText(document.searchable).includes(foldText(query))) score += 2;
  const normalized = terms.length === 0 ? 0 : Math.min(0.99, score / (terms.length * 4 + 2));
  return Number(normalized.toFixed(4));
}

function makeSnippet(document, terms, query) {
  const cleanBody = redactSensitiveContent(stripMarkdown(stripFrontmatter(document.content))).replace(/\s+/g, ' ').trim();
  if (!cleanBody) return '';
  const folded = foldText(cleanBody);
  const needle = terms.find(term => folded.includes(term)) || foldText(query);
  const index = needle ? folded.indexOf(needle) : -1;
  const start = index > 48 ? index - 48 : 0;
  return cleanBody.slice(start, start + 220).trim();
}

function parseFrontmatter(content) {
  if (!content.startsWith('---')) return {};
  const lines = content.split(/\r?\n/);
  if (lines[0].trim() !== '---') return {};
  const values = {};
  for (const line of lines.slice(1)) {
    if (line.trim() === '---') break;
    const separator = line.indexOf(':');
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim().toLowerCase();
    const value = unquoteEnvValue(line.slice(separator + 1).trim());
    if (key) values[key] = value;
  }
  return values;
}

function stripFrontmatter(content) {
  if (!content.startsWith('---')) return content;
  return content.replace(/^---\s*\r?\n[\s\S]*?\r?\n---\s*/, '');
}

function firstHeading(content) {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? cleanTitle(match[1]) : '';
}

function cleanTitle(value) {
  return stringValue(value).replace(/[#*_`]/g, '').trim();
}

function titleFromPath(relativePath) {
  const base = path.basename(removeWikiExtension(relativePath));
  return base.replace(/[-_]+/g, ' ').replace(/\s+/g, ' ').trim() || 'Documento';
}

function extractLinks(content) {
  const links = [];
  const seen = new Set();
  const add = (target, label, kind) => {
    const cleanTarget = stringValue(target).trim();
    if (!cleanTarget) return;
    const key = `${kind}:${cleanTarget}`;
    if (seen.has(key)) return;
    seen.add(key);
    links.push({ target: cleanTarget, label: stringValue(label || cleanTarget).trim(), kind });
  };

  for (const match of content.matchAll(/\[\[([^\]]+)\]\]/g)) {
    const raw = match[1].trim();
    const [targetRaw, alias] = raw.split('|', 2).map(item => item.trim());
    const [target, heading = ''] = targetRaw.split('#', 2).map(item => item.trim());
    add(heading ? `${target}#${heading}` : target, alias || targetRaw, 'wiki');
  }

  for (const match of content.matchAll(/\[([^\]]+)\]\(([^)]+)\)/g)) {
    add(match[2], match[1], 'markdown');
  }

  return links;
}

function formatLink(link) {
  if (typeof link === 'string') return link;
  const kind = stringValue(link.kind || 'link');
  const target = stringValue(link.target).trim();
  const label = stringValue(link.label).trim();
  if (!target) return '';
  return label && label !== target ? `${kind}:${target}|${label}` : `${kind}:${target}`;
}

export function redactSensitiveContent(content) {
  let redacted = stringValue(content);
  redacted = redacted.replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[redacted:private_key]');
  redacted = redacted.replace(/\b(AKIA|ASIA)[A-Z0-9]{16}\b/g, '[redacted:aws_access_key]');
  redacted = redacted.replace(/\b(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|hf_[A-Za-z0-9]{20,})\b/g, '[redacted:token]');
  redacted = redacted.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b/gi, 'Bearer [redacted:token]');
  redacted = redacted.replace(/\b(api[_-]?key|access[_-]?token|client[_-]?secret|secret|password|passwd|private[_-]?key|token)\b(\s*[:=]\s*)(['\"]?)[^\s'\"`]{8,}\3/gi, '$1$2[redacted:secret]');
  return redacted;
}

function normalizeLimit(value, fieldErrors) {
  if (value === undefined || value === null || value === '') return RFC03_LIMITS.defaultSearchLimit;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    fieldErrors.push({ field: 'limit', message: 'inteiro entre 1 e 50' });
    return RFC03_LIMITS.defaultSearchLimit;
  }
  return Math.min(parsed, RFC03_LIMITS.maxSearchLimit);
}

function isSafeDocumentID(value) {
  if (value.includes('..') || value.startsWith('/') || value.startsWith('\\')) return false;
  return /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value);
}

function normalizeDocumentID(value) {
  return pathToDocumentID(value);
}

function pathToDocumentID(value) {
  return normalizeRelativePath(removeWikiExtension(value))
    .split('/')
    .map(slugify)
    .filter(Boolean)
    .join('/');
}

function slugify(value) {
  return foldText(removeWikiExtension(value))
    .replace(/\\/g, '/')
    .replace(/[^a-z0-9/_-]+/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^[-/]+|[-/]+$/g, '');
}

function foldText(value) {
  return stringValue(value)
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLowerCase();
}

function tokenize(query) {
  return unique(foldText(query).match(/[a-z0-9_/-]+/g) || []);
}

function countOccurrences(haystack, needle) {
  if (!needle) return 0;
  let count = 0;
  let offset = 0;
  while (true) {
    const index = haystack.indexOf(needle, offset);
    if (index < 0) return count;
    count += 1;
    offset = index + needle.length;
  }
}

function removeWikiExtension(value) {
  return stringValue(value)
    .replace(/\.excalidraw\.md$/i, '')
    .replace(/\.excalidraw$/i, '')
    .replace(/\.md$/i, '');
}

function isMarkdownPath(relativePath) {
  const lower = relativePath.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.excalidraw.md');
}

function shouldSkipDirectory(relativePath, name) {
  if (name.startsWith('.')) return true;
  return ['node_modules', 'dist', 'build'].includes(name.toLowerCase()) || isSensitivePath(relativePath);
}

function isSensitivePath(relativePath) {
  const lower = normalizeRelativePath(relativePath).toLowerCase();
  const parts = lower.split('/');
  if (parts.some(part => part.startsWith('.'))) return true;
  if (parts.some(part => ['node_modules', 'dist', 'build'].includes(part))) return true;
  const name = parts.at(-1) || lower;
  if (/^\.?env($|[._-])/.test(name)) return true;
  if (/\.(pem|key|p12|pfx|kdbx|sqlite|db)$/i.test(name)) return true;
  return /(^|[-_.])(secret|secrets|credential|credentials|token|tokens|private-key|id_rsa|auth-profiles)([-_.]|$)/i.test(name);
}

function weakETag(relativePath, content, info) {
  const hash = createHash('sha256')
    .update(relativePath)
    .update('\0')
    .update(content)
    .update('\0')
    .update(String(info.mtimeMs))
    .digest('hex')
    .slice(0, 16);
  return `w/"${hash}"`;
}

function normalizeEnum(value, allowed, fallback) {
  const clean = stringValue(value).trim().toLowerCase();
  return allowed.includes(clean) ? clean : fallback;
}

function parseBoolean(value) {
  const clean = stringValue(value).trim().toLowerCase();
  return ['true', 'yes', '1', 'sim'].includes(clean);
}

function parsePositiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function stringValue(value) {
  return value === undefined || value === null ? '' : String(value);
}

function unique(values) {
  return [...new Set(values)];
}

function stripMarkdown(value) {
  return stringValue(value)
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, '$2')
    .replace(/\[\[([^\]]+)\]\]/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[#*_`>~-]/g, ' ');
}

function normalizeRelativePath(value) {
  return stringValue(value).replace(/\\/g, '/').replace(/^\/+/, '').replace(/\/{2,}/g, '/');
}

function resolveConfiguredPath(value) {
  let clean = stringValue(value).trim();
  if (!clean) return DEFAULT_REFERENCE_PATH;
  if (clean.startsWith('file://')) {
    try {
      clean = fileURLToPath(clean);
    } catch {
      clean = clean.replace(/^file:\/+/, '/');
    }
  }
  clean = clean
    .replace(/^\$\{HOME\}(?=\/|$)/, homedir())
    .replace(/^\$HOME(?=\/|$)/, homedir())
    .replace(/^~(?=\/|$)/, homedir())
    .replace(/\\([ ()[\]{}&;'"`$!#])/g, '$1');
  return path.isAbsolute(clean) ? path.normalize(clean) : path.resolve(REPO_ROOT, clean);
}

function unquoteEnvValue(value) {
  return stringValue(value).replace(/^['"]|['"]$/g, '');
}

function timedOut(started) {
  return Date.now() - started > RFC03_LIMITS.toolTimeoutMs;
}

function timeoutError(traceID) {
  return createTypedError('ERR_TIMEOUT', 'timeout na leitura do indice.', traceID, {
    resource_limit: `tool_timeout_ms=${RFC03_LIMITS.toolTimeoutMs}`
  });
}

function unavailableIndexError(err, traceID, root) {
  throw createTypedError('ERR_DEPENDENCY_UNAVAILABLE', 'wiki root indisponivel.', traceID, {
    dependency: `${root}: ${err?.code || 'unavailable'}`
  });
}
