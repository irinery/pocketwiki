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
  #authenticate(bearer, thread_id) {
    if (!UUID.test(thread_id ?? '')) fail('ERR_INVALID', 'thread_id inválido.');
    let identity;
    try { identity = this.#host.authenticate(bearer, { audience: AUDIENCE, scope: 'context.read', threadId: thread_id }); }
    catch { fail('ERR_FORBIDDEN', 'Credencial inválida.'); }
    if (identity.thread_id !== thread_id) fail('ERR_FORBIDDEN', 'Credencial sem thread vinculada.');
    this.#policy.authorize(identity);
    return identity;
  }
  // Kernel calls this only for an accepted and authorized command; it must
  // compare-and-swap expected_revision and own the durable receipt/outbox.
  async execute({ bearer, thread_id, command }) {
    const identity = this.#authenticate(bearer, thread_id);
    return this.#service.executeCommand(identity, command);
  }
  // Picker methods are private host ports, not registered wire operations.
  async previewFile({ bearer, thread_id, root, relative_path, kind }) {
    const identity = this.#authenticate(bearer, thread_id);
    return this.#service.previewFile(identity, { root, relative_path, kind });
  }
  async previewQuote({ bearer, thread_id, root, relative_path, start_byte, end_byte }) {
    const identity = this.#authenticate(bearer, thread_id);
    return this.#service.previewQuote(identity, { root, relative_path, start_byte, end_byte });
  }
  async readQuote({ bearer, thread_id, reference_id }) {
    const identity = this.#authenticate(bearer, thread_id);
    return this.#service.readQuote(identity, reference_id);
  }
  async callLocal({ bearer, thread_id, operation, input }) {
    const identity = this.#authenticate(bearer, thread_id);
    const operations = {
      'composer.stage': () => this.#service.stage(identity, input),
      'composer.draft.save': () => this.#service.saveDraft(identity, input.draft),
      'composer.pin': () => this.#service.pin(identity, input),
      'composer.resolve': () => this.#service.resolve({ ...identity, delegated_identity: identity }, input)
    };
    if (!Object.hasOwn(operations, operation) || !validateOperationInput(operation, input).valid) fail('ERR_INVALID', 'Operação local inválida.');
    return operations[operation]();
  }
}
