import http from 'node:http';

/** Trusted PocketWiki-to-Kernel control channel, backed by a private Unix socket. */
export class KernelLocalBootstrapClient {
  #socketPath;

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

  async #post(path, payload) {
    const body = JSON.stringify(payload);
    const result = await new Promise((resolve, reject) => {
      const request = http.request({
        socketPath: this.#socketPath,
        path,
        method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
        timeout: 2000
      }, (response) => {
        response.resume();
        response.on('end', () => resolve(response.statusCode));
      });
      request.on('timeout', () => request.destroy(new Error('Kernel bootstrap timeout')));
      request.on('error', reject);
      request.end(body);
    });
    if (result !== 204) throw Object.assign(new Error('Kernel rejected private bootstrap metadata'), { code: 'ERR_FORBIDDEN' });
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
