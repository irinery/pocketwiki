import { createServer } from 'node:http';
import dgram from 'node:dgram';
import { readFile, readdir, stat } from 'node:fs/promises';
import { homedir, networkInterfaces } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { handleSolutionPut } from './src/solutions/solution-ingestion.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.join(__dirname, '.env');
const DEFAULT_REFERENCE_PATH = path.join(__dirname, 'SKILL/wiki-reference');
const startupEnv = await readEnv(ENV_PATH);

const PORT = Number(envValue('POCKETWIKI_PORT', startupEnv, 8787));
const HOST = envValue('POCKETWIKI_BIND_HOST', startupEnv, '0.0.0.0');
const publicHosts = parsePublicHosts(
  envValue('POCKETWIKI_PUBLIC_HOSTS', startupEnv, '') ||
  envValue('POCKETWIKI_PUBLIC_HOST', startupEnv, '') ||
  'pocketwiki.local,pokectwiki.local'
);
const mdnsEnabled = String(envValue('POCKETWIKI_MDNS', startupEnv, 'true')).toLowerCase() !== 'false';

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/wiki-cockpit.html')) {
      return sendFile(res, path.join(__dirname, 'wiki-cockpit.html'), 'text/html; charset=utf-8');
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/offline.html') {
      return sendFile(res, path.join(__dirname, 'offline.html'), 'text/html; charset=utf-8', { 'Cache-Control': 'no-cache' }, req.method === 'HEAD');
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/manifest.webmanifest') {
      return sendFile(res, path.join(__dirname, 'manifest.webmanifest'), 'application/manifest+json; charset=utf-8', { 'Cache-Control': 'no-cache' }, req.method === 'HEAD');
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/sw.js') {
      return sendFile(res, path.join(__dirname, 'sw.js'), 'application/javascript; charset=utf-8', { 'Cache-Control': 'no-cache' }, req.method === 'HEAD');
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/favicon.ico') {
      return sendOptionalFile(res, path.join(__dirname, 'favicon.ico'), 'image/x-icon', { 'Cache-Control': 'no-cache' }, req.method === 'HEAD');
    }

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/favicon.png') {
      return sendOptionalFile(res, path.join(__dirname, 'favicon.png'), 'image/png', { 'Cache-Control': 'no-cache' }, req.method === 'HEAD');
    }

    if (req.method === 'GET' && url.pathname.startsWith('/assets/')) {
      return sendStaticAsset(res, url.pathname);
    }

    if (req.method === 'GET' && url.pathname === '/api/config') {
      const runtime = await loadRuntimeConfig({ inspectReference: true });
      return sendJson(res, {
        referenceName: runtime.reference.name,
        referenceSource: runtime.reference.source,
        referenceConfigured: runtime.reference.configured,
        referenceReadonly: runtime.reference.readonly,
        referenceAvailable: runtime.reference.available,
        referenceStatus: runtime.reference.status,
        mcpEvidence: await mcpEvidencePayload(runtime),
        lmStudioModel: runtime.ai.model,
        lmStudioBaseUrl: runtime.ai.baseUrl,
        pocketKernelBaseUrl: runtime.kernel.baseUrl,
        middlewareAuthBaseUrl: runtime.middlewareAuth.baseUrl,
        middlewareAuthProjectId: runtime.middlewareAuth.projectId,
        middlewareAuthProfileId: runtime.middlewareAuth.profileId,
        kernelProxy: true,
        middlewareAuthProxy: true
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/routes') {
      return sendJson(res, buildRoutes());
    }

    if (req.method === 'GET' && url.pathname === '/api/wiki/files') {
      const runtime = await loadRuntimeConfig({ inspectReference: true });
      if (!runtime.reference.available) {
        return sendJson(res, {
          rootName: runtime.reference.name,
          readonly: runtime.reference.readonly,
          source: runtime.reference.source,
          configured: runtime.reference.configured,
          available: false,
          status: runtime.reference.status,
          files: []
        });
      }
      const files = await listReferenceFiles(runtime.reference.path);
      return sendJson(res, {
        rootName: runtime.reference.name,
        readonly: runtime.reference.readonly,
        source: runtime.reference.source,
        configured: runtime.reference.configured,
        available: true,
        status: runtime.reference.status,
        files
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/prompts/wiki-review') {
      return sendFile(res, path.join(__dirname, 'prompts/wiki-review.md'), 'text/markdown; charset=utf-8');
    }

    const solutionRoute = matchSolutionRoute(url.pathname);
    if (req.method === 'PUT' && solutionRoute) {
      const runtime = await loadRuntimeConfig({ inspectReference: true });
      return handleSolutionPut(req, res, {
        solutionId: solutionRoute.solutionId,
        reference: runtime.reference,
        writeToken: runtime.write.token,
        maxRequestBytes: runtime.write.maxRequestBytes
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/kernel/query') {
      const runtime = await loadRuntimeConfig();
      const body = await readJsonBody(req);
      return proxyPocketKernel(res, {
        method: 'POST',
        body: JSON.stringify(body)
      }, runtime.kernel);
    }

    if (req.method === 'POST' && url.pathname === '/api/middleware/lmstudio/api-key') {
      const runtime = await loadRuntimeConfig();
      const body = await readJsonBody(req);
      return proxyMiddlewareLMStudioApiKey(res, body, runtime.middlewareAuth, runtime.ai);
    }

    if (req.method === 'POST' && url.pathname === '/api/middleware/lmstudio/status') {
      const runtime = await loadRuntimeConfig();
      const body = await readJsonBody(req);
      return proxyMiddlewareLMStudioStatus(res, body, runtime.middlewareAuth);
    }

    if (req.method === 'POST' && url.pathname === '/api/middleware/openai/login') {
      const runtime = await loadRuntimeConfig();
      const body = await readJsonBody(req);
      return proxyMiddlewareOpenAILogin(res, body, runtime.middlewareAuth);
    }

    if (req.method === 'POST' && url.pathname === '/api/middleware/openai/status') {
      const runtime = await loadRuntimeConfig();
      const body = await readJsonBody(req);
      return proxyMiddlewareOpenAIStatus(res, body, runtime.middlewareAuth);
    }

    sendJson(res, { error: 'not_found' }, 404);
  } catch (err) {
    console.warn('Request failed');
    sendJson(res, { error: 'internal_error' }, 500);
  }
});

server.on('error', err => {
  if (err.code === 'EACCES' && PORT < 1024) {
    console.error(`PocketWiki: sem permissao para abrir porta ${PORT}.`);
    console.error(`Para URL sem porta, rode com privilegio: sudo env POCKETWIKI_PORT=${PORT} node server.mjs`);
    console.error('Alternativa: mantenha 8787 e use Tailscale Serve ou um reverse proxy local.');
    process.exit(1);
  }
  if (err.code === 'EADDRINUSE') {
    console.error(`PocketWiki: porta ${PORT} ja esta em uso.`);
    console.error('Pare o processo atual ou ajuste POCKETWIKI_PORT.');
    process.exit(1);
  }
  throw err;
});

server.listen(PORT, HOST, async () => {
  const runtime = await loadRuntimeConfig({ inspectReference: true });
  const routes = buildRoutes();
  const mcpEvidence = await mcpEvidencePayload(runtime);
  console.log(`PocketWiki local: ${routes.local.join(', ')}`);
  for (const url of routes.mdns) console.log(`PocketWiki mDNS: ${url}`);
  for (const url of routes.lan) console.log(`PocketWiki LAN IP: ${url}`);
  for (const url of routes.tailscale) console.log(`PocketWiki Tailscale: ${url}`);
  if (!routes.portless) console.log('Sem porta na URL exige HTTP em :80, HTTPS em :443, Tailscale Serve ou reverse proxy.');
  console.log(`Bind: ${HOST}:${PORT}`);
  console.log(`Wiki reference: ${runtime.reference.name} (${runtime.reference.source})`);
  console.log(`MCP Evidence: ${mcpEvidence.status} (${mcpEvidence.transport}, PocketKernel inicia sob demanda)`);
  console.log(`PocketKernel: ${runtime.kernel.baseUrl}`);
  console.log(`MiddlewareAuth: ${runtime.middlewareAuth.baseUrl}`);
  console.log(`LM Studio provider: ${runtime.ai.baseUrl}`);
  if (mdnsEnabled) startMdnsResponder(publicHosts, PORT);
});

function envValue(key, values, fallback = '') {
  if (Object.prototype.hasOwnProperty.call(process.env, key)) return process.env[key];
  if (values && Object.prototype.hasOwnProperty.call(values, key)) return values[key];
  return fallback;
}

function hasEnvValue(key, values) {
  return Object.prototype.hasOwnProperty.call(process.env, key) ||
    Boolean(values && Object.prototype.hasOwnProperty.call(values, key));
}

async function loadRuntimeConfig(opts = {}) {
  const values = await readEnv(ENV_PATH);
  const referenceConfigured = hasEnvValue('POCKETWIKI_REFERENCE_PATH', values);
  const referenceRaw = envValue('POCKETWIKI_REFERENCE_PATH', values, DEFAULT_REFERENCE_PATH);
  const referencePath = resolveConfiguredPath(referenceRaw);
  const referenceStatus = opts.inspectReference ? await inspectReferencePath(referencePath) : { available: null, status: 'unchecked' };

  return {
    reference: {
      path: referencePath,
      name: path.basename(referencePath),
      source: referenceConfigured ? 'env' : 'default',
      configured: referenceConfigured,
      readonly: String(envValue('POCKETWIKI_REFERENCE_READONLY', values, 'true')).toLowerCase() !== 'false',
      available: referenceStatus.available,
      status: referenceStatus.status
    },
    ai: {
      baseUrl: trimSlash(envValue('LM_STUDIO_BASE_URL', values, 'http://localhost:1234/v1')),
      apiKey: envValue('LM_STUDIO_API_KEY', values, '') || envValue('LM_API_TOKEN', values, ''),
      model: envValue('LM_STUDIO_MODEL', values, '')
    },
    kernel: {
      baseUrl: trimSlash(envValue('POCKETKERNEL_BASE_URL', values, 'http://127.0.0.1:8080'))
    },
    middlewareAuth: {
      baseUrl: trimSlash(envValue('MIDDLEWARE_BASE_URL', values, 'http://127.0.0.1:18787')),
      clientToken: envValue('MIDDLEWARE_CLIENT_TOKEN', values, ''),
      projectId: envValue('MIDDLEWARE_PROJECT_ID', values, '') ||
        envValue('MCP_DEFAULT_PROJECT_ID', values, 'acme'),
      profileId: envValue('MIDDLEWARE_LLM_PROFILE_ID', values, '') ||
        envValue('MCP_LMSTUDIO_PROFILE_ID', values, 'default')
    },
    write: {
      token: envValue('POCKETWIKI_WRITE_TOKEN', values, ''),
      maxRequestBytes: parseRequestLimit(
        envValue('POCKETWIKI_WRITE_MAX_BYTES', values, String(8 * 1024 * 1024)),
        8 * 1024 * 1024
      )
    }
  };
}

function matchSolutionRoute(pathname) {
  const match = /^\/api\/v1\/solutions\/([^/]+)$/.exec(pathname);
  if (!match) return null;
  try {
    return { solutionId: decodeURIComponent(match[1]) };
  } catch {
    return { solutionId: '' };
  }
}

function parseRequestLimit(value, fallback) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= fallback ? parsed : fallback;
}

function resolveConfiguredPath(value) {
  let clean = String(value || '').trim();
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

  if (path.isAbsolute(clean)) return path.normalize(clean);
  return path.resolve(__dirname, clean);
}

async function inspectReferencePath(root) {
  try {
    const info = await stat(root);
    if (!info.isDirectory()) return { available: false, status: 'not_directory' };
    return { available: true, status: 'ready' };
  } catch (err) {
    if (err?.code === 'ENOENT') return { available: false, status: 'missing' };
    if (err?.code === 'EACCES' || err?.code === 'EPERM') return { available: false, status: 'permission_denied' };
    return { available: false, status: 'unavailable' };
  }
}

async function mcpEvidencePayload(runtime) {
  const script = path.join(__dirname, 'src/mcp/pocketwiki-mcp-server.mjs');
  const scriptStatus = await inspectFilePath(script);
  const args = [script, '--root', runtime.reference.path];
  const argsPortable = args.every(value => !/\s/.test(value));
  let status = 'ready';
  if (!scriptStatus.available) status = scriptStatus.status;
  else if (!runtime.reference.available) status = runtime.reference.status;
  else if (!argsPortable) status = 'args_require_wrapper';

  return {
    available: scriptStatus.available && runtime.reference.available && argsPortable,
    transport: 'stdio',
    status,
    command: 'node',
    args,
    tools: ['wiki.search', 'wiki.get_document'],
    timeoutMs: 5000,
    maxResults: 8,
    sameHostOnly: true,
    argsParsing: 'space_separated',
    argsPortable,
    note: 'PocketKernel inicia este processo sob demanda via stdio; nao ha porta MCP separada.'
  };
}

async function inspectFilePath(file) {
  try {
    const info = await stat(file);
    if (!info.isFile()) return { available: false, status: 'not_file' };
    return { available: true, status: 'ready' };
  } catch (err) {
    if (err?.code === 'ENOENT') return { available: false, status: 'mcp_script_missing' };
    if (err?.code === 'EACCES' || err?.code === 'EPERM') return { available: false, status: 'permission_denied' };
    return { available: false, status: 'unavailable' };
  }
}

function buildRoutes() {
  const addresses = allLanIpv4();
  const lan = addresses.filter(isPrivateLan).map(ip => formatHttpUrl(ip, PORT));
  const tailscale = addresses.filter(isTailscaleIp).map(ip => formatHttpUrl(ip, PORT));
  const other = addresses.filter(ip => !isPrivateLan(ip) && !isTailscaleIp(ip)).map(ip => formatHttpUrl(ip, PORT));
  return {
    port: PORT,
    bindHost: HOST,
    portless: PORT === 80,
    local: [formatHttpUrl('localhost', PORT)],
    mdns: publicHosts.map(host => formatHttpUrl(host, PORT)),
    lan: [...lan, ...other],
    tailscale
  };
}

function formatHttpUrl(host, port) {
  return port === 80 ? `http://${host}` : `http://${host}:${port}`;
}

async function readEnv(file) {
  const values = {};
  let raw = '';
  try {
    raw = await readFile(file, 'utf8');
  } catch {
    return values;
  }

  for (const line of raw.split(/\r?\n/)) {
    const clean = line.trim();
    if (!clean || clean.startsWith('#')) continue;
    const ix = clean.indexOf('=');
    if (ix === -1) continue;
    const key = clean.slice(0, ix).trim();
    let value = clean.slice(ix + 1).trim();
    value = value.replace(/^(['"])(.*)\1$/, '$2');
    values[key] = value;
  }

  return values;
}

async function listReferenceFiles(root) {
  const rootStat = await stat(root).catch(() => null);
  if (!rootStat?.isDirectory()) return [];
  const files = [];

  async function walk(dir, prefix = '') {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith('.') || ['node_modules', 'dist', 'build'].includes(entry.name)) continue;
      const full = path.join(dir, entry.name);
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await walk(full, rel);
        continue;
      }
      if (!entry.isFile()) continue;
      const info = await stat(full);
      const isIndexable = /\.md$/i.test(entry.name) || /\.excalidraw$/i.test(entry.name);
      files.push({
        path: rel,
        name: entry.name,
        size: info.size,
        type: contentType(entry.name),
        updated: info.mtimeMs,
        content: isIndexable ? await readFile(full, 'utf8') : null
      });
    }
  }

  await walk(root);
  return files;
}

async function proxyPocketKernel(res, init, kernelConfig) {
  let endpoint;
  try {
    endpoint = pocketKernelEndpoint(kernelConfig.baseUrl);
  } catch {
    return sendJson(res, { error: 'invalid_pocketkernel_endpoint' }, 502);
  }

  try {
    const upstream = await fetch(endpoint, {
      ...init,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });
    res.writeHead(upstream.status, {
      ...securityHeaders(),
      'Content-Type': upstream.headers.get('content-type') || 'application/json; charset=utf-8',
      'Cache-Control': 'no-store, no-transform'
    });
    res.end(await upstream.text());
  } catch {
    sendJson(res, { error: 'pocketkernel_proxy_failed' }, 502);
  }
}

async function proxyMiddlewareLMStudioApiKey(res, body, middlewareConfig, aiConfig) {
  if (!middlewareConfig.clientToken) {
    return sendJson(res, { error: 'middlewareauth_token_missing' }, 401);
  }
  if (!String(body.apiKey || '').trim()) {
    return sendJson(res, { error: 'lmstudio_api_key_missing' }, 400);
  }
  let endpoint;
  try {
    endpoint = middlewareAuthEndpoint(
      body.middlewareBaseUrl || middlewareConfig.baseUrl,
      `/v1/projects/${encodeURIComponent(body.projectId || middlewareConfig.projectId || 'acme')}/auth/lmstudio/api-key`
    );
  } catch {
    return sendJson(res, { error: 'invalid_middlewareauth_endpoint' }, 502);
  }
  return proxyMiddlewareAuth(res, endpoint, middlewareConfig.clientToken, {
    method: 'POST',
    body: JSON.stringify({
      profileId: body.profileId || middlewareConfig.profileId || 'default',
      baseUrl: body.baseUrl || aiConfig.baseUrl || 'http://127.0.0.1:1234',
      apiKey: body.apiKey
    })
  });
}

async function proxyMiddlewareLMStudioStatus(res, body, middlewareConfig) {
  if (!middlewareConfig.clientToken) {
    return sendJson(res, { error: 'middlewareauth_token_missing' }, 401);
  }
  const profileId = body.profileId || middlewareConfig.profileId || 'default';
  let endpoint;
  try {
    endpoint = middlewareAuthEndpoint(
      body.middlewareBaseUrl || middlewareConfig.baseUrl,
      `/v1/projects/${encodeURIComponent(body.projectId || middlewareConfig.projectId || 'acme')}/auth/lmstudio/status`
    );
    endpoint.searchParams.set('profileId', profileId);
  } catch {
    return sendJson(res, { error: 'invalid_middlewareauth_endpoint' }, 502);
  }
  return proxyMiddlewareAuth(res, endpoint, middlewareConfig.clientToken, { method: 'GET' });
}

async function proxyMiddlewareOpenAILogin(res, body, middlewareConfig) {
  if (!middlewareConfig.clientToken) {
    return sendJson(res, { error: 'middlewareauth_token_missing' }, 401);
  }
  let endpoint;
  try {
    endpoint = middlewareAuthEndpoint(
      body.middlewareBaseUrl || middlewareConfig.baseUrl,
      `/v1/projects/${encodeURIComponent(body.projectId || middlewareConfig.projectId || 'acme')}/auth/openai/login`
    );
  } catch {
    return sendJson(res, { error: 'invalid_middlewareauth_endpoint' }, 502);
  }
  return proxyMiddlewareAuth(res, endpoint, middlewareConfig.clientToken, {
    method: 'POST',
    body: JSON.stringify({
      profileId: body.profileId || middlewareConfig.profileId || 'default',
      mode: body.mode || 'device_code'
    })
  });
}

async function proxyMiddlewareOpenAIStatus(res, body, middlewareConfig) {
  if (!middlewareConfig.clientToken) {
    return sendJson(res, { error: 'middlewareauth_token_missing' }, 401);
  }
  const profileId = body.profileId || middlewareConfig.profileId || 'default';
  let endpoint;
  try {
    endpoint = middlewareAuthEndpoint(
      body.middlewareBaseUrl || middlewareConfig.baseUrl,
      `/v1/projects/${encodeURIComponent(body.projectId || middlewareConfig.projectId || 'acme')}/auth/openai/status`
    );
    endpoint.searchParams.set('profileId', profileId);
  } catch {
    return sendJson(res, { error: 'invalid_middlewareauth_endpoint' }, 502);
  }
  return proxyMiddlewareAuth(res, endpoint, middlewareConfig.clientToken, { method: 'GET' });
}

async function proxyMiddlewareAuth(res, endpoint, clientToken, init) {
  try {
    const upstream = await fetch(endpoint, {
      ...init,
      headers: {
        'Authorization': `Bearer ${clientToken}`,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });
    res.writeHead(upstream.status, {
      ...securityHeaders(),
      'Content-Type': upstream.headers.get('content-type') || 'application/json; charset=utf-8',
      'Cache-Control': 'no-store, no-transform'
    });
    res.end(await upstream.text());
  } catch {
    sendJson(res, { error: 'middlewareauth_proxy_failed' }, 502);
  }
}

function middlewareAuthEndpoint(baseUrl, suffix) {
  const url = new URL(baseUrl || 'http://127.0.0.1:18787');
  if (!isAllowedLocalBaseUrl(url)) throw new Error('non_local_middlewareauth_endpoint');
  const basePath = url.pathname.replace(/\/+$/, '');
  url.pathname = [basePath, suffix.replace(/^\/+/, '')].filter(Boolean).join('/');
  return url;
}

function pocketKernelEndpoint(baseUrl) {
  const url = new URL(baseUrl || 'http://127.0.0.1:8080');
  const pathName = url.pathname.replace(/\/+$/, '');
  if (!pathName || pathName === '/') url.pathname = '/v1/kernel';
  else if (pathName !== '/v1/kernel' && pathName !== '/api/kernel/query') url.pathname = `${pathName}/v1/kernel`;
  else url.pathname = pathName;
  return url.toString();
}

async function readJsonBody(req) {
  const maxBytes = 2 * 1024 * 1024;
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw new Error('request_body_too_large');
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  return raw ? JSON.parse(raw) : {};
}

async function sendFile(res, file, type, headers = {}, headOnly = false) {
  const body = await readFile(file);
  res.writeHead(200, { ...securityHeaders(), 'Content-Type': type, 'Content-Length': body.length, ...headers });
  res.end(headOnly ? null : body);
}

async function sendOptionalFile(res, file, type, headers = {}, headOnly = false) {
  try {
    return await sendFile(res, file, type, headers, headOnly);
  } catch {
    return sendNotFound(res);
  }
}

async function sendStaticAsset(res, pathname) {
  const root = path.join(__dirname, 'assets');
  const requested = path.resolve(__dirname, decodeURIComponent(pathname.replace(/^\/+/, '')));
  if (!requested.startsWith(root + path.sep)) return sendNotFound(res);
  return sendOptionalFile(res, requested, contentType(requested));
}

function sendNotFound(res) {
  res.writeHead(404, { ...securityHeaders(), 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('not_found');
}

function sendJson(res, payload, status = 200) {
  res.writeHead(status, {
    ...securityHeaders(),
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(payload));
}

function securityHeaders() {
  return {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer'
  };
}

function contentType(file) {
  if (/\.excalidraw$/i.test(file)) return 'application/vnd.excalidraw+json';
  if (/\.canvas$/i.test(file)) return 'application/vnd.obsidian.canvas+json';
  if (/\.drawio$/i.test(file)) return 'application/vnd.jgraph.mxfile';
  if (/\.md$/i.test(file)) return 'text/markdown';
  if (/\.ico$/i.test(file)) return 'image/x-icon';
  if (/\.png$/i.test(file)) return 'image/png';
  if (/\.svg$/i.test(file)) return 'image/svg+xml';
  if (/\.jpe?g$/i.test(file)) return 'image/jpeg';
  if (/\.webp$/i.test(file)) return 'image/webp';
  if (/\.html$/i.test(file)) return 'text/html';
  if (/\.js$/i.test(file)) return 'application/javascript';
  if (/\.json$/i.test(file)) return 'application/json';
  if (/\.webmanifest$/i.test(file)) return 'application/manifest+json';
  if (/\.ya?ml$/i.test(file)) return 'text/yaml';
  if (/\.txt$/i.test(file)) return 'text/plain';
  return 'application/octet-stream';
}

function trimSlash(value) {
  return String(value || '').replace(/\/+$/, '');
}

function isAllowedLocalBaseUrl(url) {
  if (!['http:', 'https:'].includes(url.protocol)) return false;
  const host = url.hostname.toLowerCase();
  if (host === 'localhost' || host.endsWith('.local')) return true;
  if (host === '::1') return true;
  const octets = host.split('.').map(Number);
  if (octets.length !== 4 || octets.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  return octets[0] === 10 ||
    octets[0] === 127 ||
    (octets[0] === 169 && octets[1] === 254) ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168) ||
    (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127);
}

function parsePublicHosts(value) {
  const hosts = String(value || '')
    .split(',')
    .map(normalizeLocalHost)
    .filter(Boolean);
  return [...new Set(hosts)];
}

function normalizeLocalHost(value) {
  const clean = String(value || '').trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '').replace(/:\d+$/, '');
  if (!clean) return '';
  return clean.endsWith('.local') ? clean : `${clean}.local`;
}

function startMdnsResponder(hostnames, port) {
  const ip = allLanIpv4()[0];
  if (!ip) {
    console.warn('mDNS: nenhum IPv4 LAN encontrado');
    return;
  }

  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  const service = '_http._tcp.local';
  const instances = hostnames.map(hostname => ({
    hostname,
    instance: `PocketWiki on ${hostname}._http._tcp.local`
  }));

  socket.on('error', err => console.warn(`mDNS: ${err.message}`));
  socket.on('message', (msg, rinfo) => {
    const questions = parseDnsQuestions(msg);
    if (!questions.length) return;

    const answers = [];
    for (const q of questions) {
      const name = q.name.toLowerCase();
      const wantsAny = q.type === 255;

      for (const item of instances) {
        const hostName = item.hostname.toLowerCase();
        const instanceName = item.instance.toLowerCase();

        if ((name === hostName || name === `${hostName}.`) && (wantsAny || q.type === 1)) {
          answers.push(aRecord(item.hostname, ip));
        }

        if ((name === instanceName || name === `${instanceName}.`) && (wantsAny || q.type === 33)) {
          answers.push(srvRecord(item.instance, item.hostname, port));
        }

        if ((name === instanceName || name === `${instanceName}.`) && (wantsAny || q.type === 16)) {
          answers.push(txtRecord(item.instance, ['path=/']));
        }
      }

      if ((name === service || name === `${service}.`) && (wantsAny || q.type === 12)) {
        for (const item of instances) answers.push(ptrRecord(service, item.instance));
      }
    }

    if (!answers.length) return;
    const packet = dnsResponse(answers);
    socket.send(packet, 5353, '224.0.0.251');
    if (rinfo.port !== 5353) socket.send(packet, rinfo.port, rinfo.address);
  });

  socket.bind(5353, () => {
    socket.addMembership('224.0.0.251');
    socket.setMulticastTTL(255);
    socket.setMulticastLoopback(true);
    console.log(`mDNS: ${hostnames.join(', ')} -> ${ip}`);
    const records = [];
    for (const item of instances) {
      records.push(
        aRecord(item.hostname, ip),
        ptrRecord(service, item.instance),
        srvRecord(item.instance, item.hostname, port),
        txtRecord(item.instance, ['path=/'])
      );
    }
    const announce = dnsResponse(records);
    socket.send(announce, 5353, '224.0.0.251');
  });
}

function allLanIpv4() {
  const addresses = [];
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family === 'IPv4' && !entry.internal && !entry.address.startsWith('169.254.')) addresses.push(entry.address);
    }
  }
  return addresses.sort((a, b) => Number(!isPrivateLan(a)) - Number(!isPrivateLan(b)));
}

function isPrivateLan(ip) {
  return /^10\./.test(ip) || /^192\.168\./.test(ip) || /^172\.(1[6-9]|2\d|3[0-1])\./.test(ip);
}

function isTailscaleIp(ip) {
  return /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(ip);
}

function parseDnsQuestions(msg) {
  if (msg.length < 12) return [];
  const qdcount = msg.readUInt16BE(4);
  const questions = [];
  let offset = 12;
  for (let i = 0; i < qdcount; i++) {
    const parsed = readDnsName(msg, offset);
    if (!parsed || parsed.offset + 4 > msg.length) break;
    offset = parsed.offset;
    questions.push({
      name: parsed.name,
      type: msg.readUInt16BE(offset),
      klass: msg.readUInt16BE(offset + 2)
    });
    offset += 4;
  }
  return questions;
}

function readDnsName(msg, offset, seen = 0) {
  const labels = [];
  let jumped = false;
  let next = offset;

  while (offset < msg.length) {
    const len = msg[offset];
    if (len === 0) {
      offset += 1;
      return { name: labels.join('.'), offset: jumped ? next : offset };
    }
    if ((len & 0xc0) === 0xc0) {
      if (offset + 1 >= msg.length || seen > 8) return null;
      const ptr = ((len & 0x3f) << 8) | msg[offset + 1];
      if (!jumped) next = offset + 2;
      jumped = true;
      offset = ptr;
      seen += 1;
      continue;
    }
    offset += 1;
    if (offset + len > msg.length) return null;
    labels.push(msg.subarray(offset, offset + len).toString('utf8'));
    offset += len;
  }

  return null;
}

function dnsResponse(records) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0);
  header.writeUInt16BE(0x8400, 2);
  header.writeUInt16BE(0, 4);
  header.writeUInt16BE(records.length, 6);
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);
  return Buffer.concat([header, ...records]);
}

function aRecord(name, ip) {
  return resourceRecord(name, 1, 120, Buffer.from(ip.split('.').map(Number)));
}

function ptrRecord(name, target) {
  return resourceRecord(name, 12, 4500, encodeDnsName(target), false);
}

function srvRecord(name, target, port) {
  const meta = Buffer.alloc(6);
  meta.writeUInt16BE(0, 0);
  meta.writeUInt16BE(0, 2);
  meta.writeUInt16BE(port, 4);
  return resourceRecord(name, 33, 120, Buffer.concat([meta, encodeDnsName(target)]));
}

function txtRecord(name, values) {
  const parts = values.map(value => {
    const text = Buffer.from(value);
    return Buffer.concat([Buffer.from([text.length]), text]);
  });
  return resourceRecord(name, 16, 120, Buffer.concat(parts));
}

function resourceRecord(name, type, ttl, data, flush = true) {
  const head = Buffer.alloc(10);
  head.writeUInt16BE(type, 0);
  head.writeUInt16BE(flush ? 0x8001 : 0x0001, 2);
  head.writeUInt32BE(ttl, 4);
  head.writeUInt16BE(data.length, 8);
  return Buffer.concat([encodeDnsName(name), head, data]);
}

function encodeDnsName(name) {
  const labels = String(name).replace(/\.$/, '').split('.').filter(Boolean);
  const parts = labels.map(label => {
    const value = Buffer.from(label);
    return Buffer.concat([Buffer.from([value.length]), value]);
  });
  return Buffer.concat([...parts, Buffer.from([0])]);
}
