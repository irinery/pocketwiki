import http from 'node:http';

/** Trusted PocketWiki-to-Kernel control channel, backed by a private Unix socket. */
export class KernelLocalBootstrapClient {
  #socketPath;
  #agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  #socket;
  #closed = false;

  constructor({ socketPath }) {
    if (typeof socketPath !== 'string' || !socketPath) throw new TypeError('Kernel bootstrap socket path is required');
    this.#socketPath = socketPath;
  }

  registerAggregateGrant(grant) {
    return this.#post('/v1/grants', { grant: normalizeGrant(grant) });
  }

  persistVerifier(verifier) {
    if (Object.hasOwn(verifier, 'bearer')) throw new TypeError('Only a token hash may cross the bootstrap channel');
    return this.#post('/v1/verifiers', { verifier: normalizeVerifier(verifier) });
  }

  close() {
    this.#closed = true;
    this.#agent.destroy();
  }

  async #post(path, payload) {
    if (this.#closed) throw new Error('Kernel bootstrap session closed');
    const body = JSON.stringify(payload);
    try {
    const result = await new Promise((resolve, reject) => {
      let timer;
      const done = (error, status) => {
        clearTimeout(timer);
        if (error) reject(error); else resolve(status);
      };
      const request = http.request({
        socketPath: this.#socketPath,
        agent: this.#agent,
        path,
        method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
        timeout: 2000
      }, (response) => {
        response.resume();
        response.on('end', () => done(null, response.statusCode));
        response.on('aborted', () => done(new Error('Kernel bootstrap response aborted')));
        response.on('error', (error) => done(error));
      });
      request.on('socket', (socket) => {
        if (this.#socket && this.#socket !== socket) { this.close(); request.destroy(new Error('Kernel bootstrap session replaced')); return; }
        if (!this.#socket) {
          this.#socket = socket;
          socket.once('close', () => { this.#closed = true; this.#agent.destroy(); });
        }
      });
      request.on('timeout', () => request.destroy(new Error('Kernel bootstrap timeout')));
      request.on('error', (error) => done(error));
      timer = setTimeout(() => request.destroy(new Error('Kernel bootstrap deadline exceeded')), 2000);
      request.end(body);
    });
    if (result !== 204) throw Object.assign(new Error('Kernel rejected private bootstrap metadata'), { code: 'ERR_FORBIDDEN' });
    } catch (error) {
      this.close();
      throw error;
    }
  }
}

function normalizeGrant(grant) {
  return {
    principal_id: grant.principal_id,
    environment_id: grant.environment_id,
    audience: grant.audience,
    aggregate_id: grant.aggregate_id,
    scopes: [...grant.scopes]
  };
}

function normalizeVerifier(verifier) {
  return {
    token_sha256: verifier.token_sha256,
    principal_id: verifier.principal_id,
    environment_id: verifier.environment_id,
    audience: verifier.audience,
    aggregate_id: verifier.aggregate_id,
    scopes: [...verifier.scopes],
    expires_at_ms: verifier.expires_at_ms,
    revoked: Boolean(verifier.revoked)
  };
}
