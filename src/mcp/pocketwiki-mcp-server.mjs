#!/usr/bin/env node
import { stdin, stdout } from 'node:process';
import {
  createTypedError,
  getWikiDocument,
  RFC03_LIMITS,
  resolveWikiRoot,
  searchWiki
} from './pocketwiki-evidence-core.mjs';

const SERVER_INFO = Object.freeze({
  name: 'pocketwiki-evidence-server',
  version: '0.1.0'
});

const TOOLS = Object.freeze([
  {
    name: 'wiki.search',
    description: 'Busca evidencias seguras na PocketWiki local sem HTTP e sem UI.',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['query'],
      properties: {
        query: {
          type: 'string',
          minLength: 1,
          maxLength: RFC03_LIMITS.maxQueryChars,
          description: 'Texto de busca.'
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: RFC03_LIMITS.maxSearchLimit,
          default: RFC03_LIMITS.defaultSearchLimit
        },
        include_deprecated: {
          type: 'boolean',
          default: false
        },
        trace_id: {
          type: 'string'
        }
      }
    }
  },
  {
    name: 'wiki.get_document',
    description: 'Le um documento da PocketWiki como evidencia redigida e evidence_only.',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['document_id'],
      properties: {
        document_id: {
          type: 'string',
          minLength: 1,
          maxLength: RFC03_LIMITS.maxDocumentIDChars
        },
        redaction_mode: {
          type: 'string',
          enum: ['basic'],
          default: 'basic'
        },
        include_links: {
          type: 'boolean',
          default: true
        },
        trace_id: {
          type: 'string'
        }
      }
    }
  }
]);

const rootArg = parseRootArg(process.argv.slice(2));
const wikiRoot = await resolveWikiRoot({ root: rootArg });
const decoder = new TextDecoder();
let buffer = '';
let contentLength = null;
let sawHeaderFraming = false;

stdin.setEncoding('utf8');
stdin.on('data', chunk => {
  buffer += chunk;
  drainInput().catch(err => {
    writeMessage(jsonRPCError(null, -32603, 'internal_error', sanitizeError(err)));
  });
});

stdin.on('end', () => {
  if (buffer.trim()) {
    for (const line of buffer.split(/\r?\n/).map(item => item.trim()).filter(Boolean)) {
      handleRawMessage(line).catch(err => {
        writeMessage(jsonRPCError(null, -32603, 'internal_error', sanitizeError(err)));
      });
    }
  }
});

async function drainInput() {
  while (buffer.length > 0) {
    if (contentLength !== null) {
      const marker = '\r\n\r\n';
      const headerEnd = buffer.indexOf(marker);
      if (headerEnd < 0) return;
      const bodyStart = headerEnd + marker.length;
      if (buffer.length < bodyStart + contentLength) return;
      const body = buffer.slice(bodyStart, bodyStart + contentLength);
      buffer = buffer.slice(bodyStart + contentLength);
      contentLength = null;
      await handleRawMessage(body);
      continue;
    }

    const headerMatch = buffer.match(/^Content-Length:\s*(\d+)\r?\n/i);
    if (headerMatch) {
      sawHeaderFraming = true;
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      contentLength = Number(headerMatch[1]);
      continue;
    }

    const newline = buffer.indexOf('\n');
    if (newline < 0) return;
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) await handleRawMessage(line);
  }
}

async function handleRawMessage(raw) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    writeMessage(jsonRPCError(null, -32700, 'parse_error'));
    return;
  }

  const response = await handleMessage(message);
  if (response) writeMessage(response);
}

async function handleMessage(message) {
  if (message.method === 'notifications/initialized' || message.method?.startsWith('notifications/')) {
    return null;
  }

  switch (message.method) {
  case 'initialize':
    return ok(message.id, {
      protocolVersion: message.params?.protocolVersion || '2024-11-05',
      capabilities: {
        tools: {}
      },
      serverInfo: SERVER_INFO
    });
  case 'tools/list':
    return ok(message.id, { tools: TOOLS });
  case 'tools/call':
    return ok(message.id, await callTool(message.params || {}));
  default:
    return jsonRPCError(message.id ?? null, -32601, 'method_not_found', { method: message.method || '' });
  }
}

async function callTool(params) {
  const name = params.name || '';
  const args = params.arguments || {};

  let payload;
  if (name === 'wiki.search') {
    payload = await safeToolCall(() => searchWiki(wikiRoot, args), args.trace_id);
  } else if (name === 'wiki.get_document') {
    payload = await safeToolCall(() => getWikiDocument(wikiRoot, args), args.trace_id);
  } else {
    payload = createTypedError('ERR_VALIDATION', 'tool desconhecida.', args.trace_id || '', {
      field_errors: [{ field: 'name', message: 'use wiki.search ou wiki.get_document' }]
    });
  }

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(payload)
      }
    ],
    structuredContent: payload,
    isError: payload.ok === false
  };
}

async function safeToolCall(fn, traceID = '') {
  try {
    return await fn();
  } catch (err) {
    if (err && err.ok === false) return err;
    return createTypedError('ERR_CONFLICT', 'falha interna sanitizada.', traceID, {
      dependency: sanitizeError(err)
    });
  }
}

function ok(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function jsonRPCError(id, code, message, data) {
  return {
    jsonrpc: '2.0',
    id,
    error: {
      code,
      message,
      ...(data === undefined ? {} : { data })
    }
  };
}

function writeMessage(message) {
  const json = JSON.stringify(message);
  if (sawHeaderFraming) {
    stdout.write(`Content-Length: ${Buffer.byteLength(json, 'utf8')}\r\n\r\n${json}`);
  } else {
    stdout.write(`${json}\n`);
  }
}

function parseRootArg(args) {
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index];
    if (item === '--root') return args[index + 1] || '';
    if (item.startsWith('--root=')) return item.slice('--root='.length);
  }
  return '';
}

function sanitizeError(err) {
  const message = err?.message || err?.code || String(err || 'unknown');
  return message.replace(process.cwd(), '[cwd]');
}

void decoder;
