import { validateOperationInput } from '../contracts/validate.mjs';
import { UUID, fail } from './service.mjs';

const AUDIENCE = 'pocketwiki.context.v1';

// Grants are installed by the trusted host, never supplied in a request.
export class ComposerPolicy {
  #grants;
  constructor(grants) {
    if (!Array.isArray(grants)) throw new TypeError('Explicit grants are required');
    this.#grants = grants.map((grant) => {
      if (!UUID.test(grant?.principal_id ?? '') || !UUID.test(grant?.environment_id ?? '') || !UUID.test(grant?.thread_id ?? '') || !Array.isArray(grant.roots) || grant.roots.some((root) => typeof root !== 'string' || !root.startsWith('/'))) throw new TypeError('Invalid composer grant');
      return Object.freeze({ principal_id: grant.principal_id, environment_id: grant.environment_id, thread_id: grant.thread_id, roots: Object.freeze([...grant.roots]) });
    });
  }
  #grant(auth) { return this.#grants.find((grant) => grant.principal_id === auth.principal_id && grant.environment_id === auth.environment_id && grant.thread_id === auth.thread_id); }
  authorize(auth) { if (!this.#grant(auth)) fail('ERR_FORBIDDEN', 'Thread não concedida.'); }
  rootsFor(auth) { this.authorize(auth); return [...this.#grant(auth).roots]; }
}

// This boundary verifies E1's local bearer. Mutations still require the E1
// command ledger at the host; this class is not an HTTP command dispatcher.
export class ComposerGateway {
  #service;
  #host;
  #policy;
  constructor({ service, credentialHost, policy }) {
    if (!service || typeof credentialHost?.authenticate !== 'function' || !(policy instanceof ComposerPolicy)) throw new TypeError('Composer service, credential host and policy are required');
    this.#service = service;
    this.#host = credentialHost;
    this.#policy = policy;
    service.rootsFor = (auth) => policy.rootsFor(auth);
  }
  async call({ bearer, thread_id, operation, input }) {
    if (!UUID.test(thread_id ?? '')) fail('ERR_INVALID', 'thread_id inválido.');
    let identity;
    try { identity = this.#host.authenticate(bearer, { audience: AUDIENCE, scope: 'context.read', threadId: thread_id }); }
    catch { fail('ERR_FORBIDDEN', 'Credencial inválida.'); }
    if (identity.thread_id !== thread_id) fail('ERR_FORBIDDEN', 'Credencial sem thread vinculada.');
    this.#policy.authorize(identity);
    const operations = {
      'composer.prepare': () => this.#service.prepare(identity, input),
      'composer.stage': () => this.#service.stage(identity, input),
      'composer.draft.save': () => this.#service.saveDraft(identity, input.draft),
      'composer.resolve': () => this.#service.resolve({ ...identity, delegated_identity: identity }, input),
      'composer.pin': () => this.#service.pin(identity, input)
    };
    if (!Object.hasOwn(operations, operation)) fail('ERR_INVALID', 'Operação desconhecida.');
    if (!validateOperationInput(operation, input).valid) fail('ERR_INVALID', 'Entrada fora do contrato.');
    return operations[operation]();
  }
}
