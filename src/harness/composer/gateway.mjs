import path from 'node:path';
import { fstatSync } from 'node:fs';
import { validateAgainst, validateOperationInput } from '../contracts/validate.mjs';
import { UUID, canonicalJSON, digest, fail, isPlainObject } from './service.mjs';

const AUDIENCE = 'pocketwiki.context.v1';
const boundPolicies = new WeakMap();

// Grants are installed by the trusted host, never supplied in a request.
export class ComposerPolicy {
  #grants;
  constructor(grants) {
    if (!Array.isArray(grants)) throw new TypeError('Explicit grants are required');
    this.#grants = grants.map((grant) => {
      if (!UUID.test(grant?.principal_id ?? '') || !UUID.test(grant?.environment_id ?? '') || !UUID.test(grant?.thread_id ?? '') || !Array.isArray(grant.roots) || grant.roots.some((root) => !root || typeof root.path !== 'string' || !path.isAbsolute(root.path) || !Number.isInteger(root.fd) || root.fd < 0 || !fstatSync(root.fd).isDirectory())) throw new TypeError('Invalid composer grant');
      return Object.freeze({ principal_id: grant.principal_id, environment_id: grant.environment_id, thread_id: grant.thread_id, roots: Object.freeze(grant.roots.map((root) => { const stat = fstatSync(root.fd, { bigint: true }); return Object.freeze({ path: path.resolve(root.path), fd: root.fd, dev: stat.dev, ino: stat.ino }); })) });
    });
  }
  #grant(auth) { return this.#grants.find((grant) => grant.principal_id === auth.principal_id && grant.environment_id === auth.environment_id && grant.thread_id === auth.thread_id); }
  authorize(auth) { if (!this.#grant(auth)) fail('ERR_FORBIDDEN', 'Thread não concedida.'); }
  rootHandle(auth, root) {
    this.authorize(auth);
    const grant = this.#grant(auth).roots.find((item) => item.path === root);
    if (!grant) fail('ERR_FORBIDDEN', 'Root não concedido.');
    try {
      const stat = fstatSync(grant.fd, { bigint: true });
      if (!stat.isDirectory() || stat.dev !== grant.dev || stat.ino !== grant.ino) fail('ERR_FORBIDDEN', 'Concessão de root alterada.');
    } catch { fail('ERR_FORBIDDEN', 'Concessão de root indisponível.'); }
    return grant.fd;
  }
}

// This boundary verifies E1's local bearer. Mutations still require the E1
// command ledger at the host; this class is not an HTTP command dispatcher.
export class ComposerGateway {
  #service;
  #host;
  #policy;
  #verifyAccepted;
  constructor({ service, credentialHost, policy, verifyAccepted = null }) {
    if (!service || typeof credentialHost?.authenticate !== 'function' || !(policy instanceof ComposerPolicy)) throw new TypeError('Composer service, credential host and policy are required');
    const existing = boundPolicies.get(service);
    if (existing && existing !== policy) throw new TypeError('Service is already bound to a different policy');
    boundPolicies.set(service, policy);
    this.#service = service;
    this.#host = credentialHost;
    this.#policy = policy;
    if (verifyAccepted !== null && typeof verifyAccepted !== 'function') throw new TypeError('Receipt verifier must be a function');
    this.#verifyAccepted = verifyAccepted;
    service.rootHandleFor = (auth, root) => policy.rootHandle(auth, root);
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
  // verifyAccepted is a trusted Kernel port; it receives no client payload and
  // returns authoritative receipt metadata for this identity and command ID.
  async executeAccepted({ bearer, thread_id, command }) {
    const identity = this.#authenticate(bearer, thread_id);
    if (!validateAgainst('command', command).valid || command.operation !== 'composer.prepare') fail('ERR_INVALID', 'Comando inválido.');
    if (command.environment_id !== identity.environment_id || command.input.thread_id !== thread_id) fail('ERR_FORBIDDEN', 'Identidade do comando divergente.');
    if (!this.#verifyAccepted) fail('ERR_UNAVAILABLE', 'Verificador de receipt indisponível.');
    let receipt;
    try {
      receipt = await this.#verifyAccepted(Object.freeze({ principal_id: identity.principal_id, environment_id: identity.environment_id, thread_id, command_id: command.command_id }));
    } catch { fail('ERR_UNAVAILABLE', 'Verificação de receipt indisponível.'); }
    const fields = ['receipt_id', 'command_id', 'principal_id', 'environment_id', 'thread_id', 'operation', 'command_sha256', 'state'];
    const expectedHash = digest(Buffer.from(canonicalJSON(command), 'utf8'));
    if (!isPlainObject(receipt) || Object.keys(receipt).length !== fields.length || fields.some((field) => !Object.hasOwn(receipt, field)) || !UUID.test(receipt.receipt_id ?? '') || receipt.command_id !== command.command_id || receipt.principal_id !== identity.principal_id || receipt.environment_id !== identity.environment_id || receipt.thread_id !== thread_id || receipt.operation !== command.operation || receipt.command_sha256 !== expectedHash || !['accepted', 'pending'].includes(receipt.state)) fail('ERR_FORBIDDEN', 'Receipt não autoriza esta intenção.');
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
