import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { Scope } from './scopes.mjs';

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const LOCAL_CREDENTIAL_TTL_MS = 900_000;

/** Process-local bearer issuer. Only the trusted host can construct this object. */
export class LocalCredentialHost {
  #verifiers = new Map();
  #identity;
  #grantedScopes;
  #deliverBearer;
  #persistVerifier;
  #now;

  constructor({ principalId, environmentId, audience, grantedScopes, deliverBearer, persistVerifier = async () => {}, now = () => Date.now() }) {
    if (!isUUID(principalId) || !isUUID(environmentId)) throw new TypeError('Host identity must be UUIDs');
    if (typeof audience !== 'string' || !audience) throw new TypeError('Audience is required');
    if (typeof deliverBearer !== 'function') throw new TypeError('A private process delivery channel is required');
    this.#identity = Object.freeze({ principal_id: principalId, environment_id: environmentId, audience });
    this.#grantedScopes = new Set(normalizeScopes(grantedScopes));
    this.#deliverBearer = deliverBearer;
    this.#persistVerifier = persistVerifier;
    if (typeof now !== 'function') throw new TypeError('A clock function is required');
    this.#now = now;
  }

  async bootstrap(requestedScopes, { threadId } = {}) {
    const requested = normalizeScopes(requestedScopes);
    const scopes = requested.filter((scope) => this.#grantedScopes.has(scope));
    if (scopes.length !== requested.length) throw authError('ERR_FORBIDDEN', 'Requested scopes exceed local host grant');
    if (threadId !== undefined && !isUUID(threadId)) throw authError('ERR_INVALID', 'thread_id must be a UUID');

    const bearer = randomBytes(32).toString('base64url');
    const tokenHash = sha256(bearer);
    const expiresAtMS = this.#now() + LOCAL_CREDENTIAL_TTL_MS;
    const metadata = Object.freeze({
      principal_id: this.#identity.principal_id,
      environment_id: this.#identity.environment_id,
      ...(threadId ? { thread_id: threadId } : {}),
      scopes: Object.freeze(scopes),
      audience: this.#identity.audience,
      expires_at_ms: expiresAtMS
    });
    const verifier = Object.freeze({ token_sha256: tokenHash, ...metadata, revoked: false });
    await this.#persistVerifier(verifier);
    this.#verifiers.set(tokenHash, verifier);
    try {
      await this.#deliverBearer(Object.freeze({ bearer, metadata }));
    } catch (error) {
      const revoked = Object.freeze({ ...verifier, revoked: true });
      await this.#persistVerifier(revoked);
      this.#verifiers.set(tokenHash, revoked);
      throw error;
    }
    return metadata;
  }

  authenticate(bearer, { audience, scope, principalId, environmentId, threadId } = {}) {
    if (typeof bearer !== 'string' || !bearer) throw authError('ERR_FORBIDDEN', 'Missing local credential');
    const candidate = Buffer.from(sha256(bearer), 'hex');
    const verifier = [...this.#verifiers.entries()].find(([storedHash]) => {
      const expected = Buffer.from(storedHash, 'hex');
      return candidate.length === expected.length && timingSafeEqual(candidate, expected);
    })?.[1];
    if (!verifier || verifier.revoked) throw authError('ERR_FORBIDDEN', 'Invalid local credential');
    if (this.#now() >= verifier.expires_at_ms) throw authError('ERR_EXPIRED', 'Local credential expired');
    if (audience !== verifier.audience) throw authError('ERR_FORBIDDEN', 'Credential audience mismatch');
    if (principalId !== undefined && principalId !== verifier.principal_id) throw authError('ERR_FORBIDDEN', 'Credential principal mismatch');
    if (environmentId !== undefined && environmentId !== verifier.environment_id) throw authError('ERR_FORBIDDEN', 'Credential environment mismatch');
    if (verifier.thread_id && threadId !== verifier.thread_id) throw authError('ERR_FORBIDDEN', 'Credential thread mismatch');
    if (scope && !verifier.scopes.includes(scope)) throw authError('ERR_FORBIDDEN', 'Credential scope mismatch');
    return Object.freeze({
      principal_id: verifier.principal_id,
      environment_id: verifier.environment_id,
      ...(verifier.thread_id ? { thread_id: verifier.thread_id } : {}),
      scopes: verifier.scopes,
      audience: verifier.audience,
      expires_at_ms: verifier.expires_at_ms
    });
  }

  async revoke(bearer) {
    if (typeof bearer !== 'string' || !bearer) return false;
    const hash = sha256(bearer);
    const verifier = this.#verifiers.get(hash);
    if (!verifier) return false;
    const revoked = Object.freeze({ ...verifier, revoked: true });
    await this.#persistVerifier(revoked);
    this.#verifiers.set(hash, revoked);
    return true;
  }
}

function normalizeScopes(scopes) {
  if (!Array.isArray(scopes) || new Set(scopes).size !== scopes.length || scopes.some((scope) => !Scope.includes(scope))) {
    throw authError('ERR_INVALID', 'Scopes must be a unique closed Scope[]');
  }
  return [...scopes].sort();
}

function isUUID(value) {
  return typeof value === 'string' && uuidPattern.test(value);
}

function sha256(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function authError(code, message) {
  return Object.assign(new Error(message), { code });
}
