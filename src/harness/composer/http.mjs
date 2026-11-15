import http from 'node:http';
import { ComposerError, isPlainObject } from './service.mjs';

const MAX_REQUEST_BYTES = 1024 * 1024;
const statuses = { ERR_INVALID: 400, ERR_FORBIDDEN: 403, ERR_CONTEXT_STALE: 409, ERR_UNAVAILABLE: 503, ERR_TIMEOUT: 504 };
function respond(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(body);
}
async function readBody(req, field) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_REQUEST_BYTES) throw new ComposerError('ERR_INVALID', 'Requisição excede o limite.');
    chunks.push(chunk);
  }
  let body;
  try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new ComposerError('ERR_INVALID', 'JSON inválido.'); }
  if (!isPlainObject(body) || Object.keys(body).length !== 2 || !Object.hasOwn(body, 'thread_id') || !Object.hasOwn(body, field)) throw new ComposerError('ERR_INVALID', 'Entrada inválida.');
  return body;
}

// Private E2 context endpoint. Bind is intentionally fixed to loopback; a
// remote authenticated TLS transport is a separate E3 integration.
export async function startComposerHTTP({ gateway }) {
  if (!gateway || typeof gateway.callLocal !== 'function') throw new TypeError('Composer gateway required');
  const server = http.createServer(async (req, res) => {
    try {
      if (req.method !== 'POST' || !['/v1/composer/pin', '/v1/composer/resolve', '/v1/composer/execute'].includes(req.url) || !/^application\/json(?:\s*;|\s*$)/i.test(req.headers['content-type'] ?? '')) throw new ComposerError('ERR_INVALID', 'Rota ou conteúdo inválido.');
      const bearer = /^Bearer ([A-Za-z0-9_-]+)$/.exec(req.headers.authorization ?? '')?.[1];
      if (!bearer) throw new ComposerError('ERR_FORBIDDEN', 'Credencial ausente.');
      const isExecute = req.url.endsWith('/execute');
      const body = await readBody(req, isExecute ? 'command' : 'input');
      if (isExecute) {
        const result = await gateway.executeAccepted({ bearer, thread_id: body.thread_id, command: body.command });
        respond(res, 200, result);
        return;
      }
      const operation = req.url.endsWith('/pin') ? 'composer.pin' : 'composer.resolve';
      const result = await gateway.callLocal({ bearer, thread_id: body.thread_id, operation, input: body.input });
      respond(res, 200, result);
    } catch (error) {
      const safe = error instanceof ComposerError ? error : new ComposerError('ERR_UNAVAILABLE', 'Serviço indisponível.');
      if (!res.headersSent) respond(res, statuses[safe.code] ?? 503, safe.toJSON());
      else res.destroy();
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve(); }); });
  return server;
}
