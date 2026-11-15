import { ComposerPreparationService } from './preparation.mjs';
import { fail, isPlainObject, ownerKey, SHA256, UUID, validateAuth } from './service.mjs';

export class ComposerContextService extends ComposerPreparationService {
  pin(auth, { prepared_id, command_id, retain }) {
    validateAuth(auth);
    if (!UUID.test(prepared_id ?? '') || !UUID.test(command_id ?? '') || typeof retain !== 'boolean') fail('ERR_INVALID', 'Entrada de pin inválida.');
    this._collectExpired();
    const prepared = this.state.prepared.find((item) => item.prepared_id === prepared_id && item.owner === ownerKey(auth));
    if (!prepared) fail('ERR_CONTEXT_STALE', 'Contexto preparado indisponível.');
    if (prepared.expired && retain) fail('ERR_CONTEXT_STALE', 'Contexto expirado.');
    if (retain && !prepared.pins.includes(command_id)) prepared.pins.push(command_id);
    if (!retain) prepared.pins = prepared.pins.filter((id) => id !== command_id);
    this._collectExpired();
    this._persist();
    return { retained: prepared.pins.includes(command_id) };
  }

  resolve(auth, input) {
    validateAuth(auth);
    if (!isPlainObject(input) || Object.keys(input).some((key) => !['prepared_id', 'manifest_sha256'].includes(key))) fail('ERR_INVALID', 'Entrada de resolve inválida.');
    const { prepared_id, manifest_sha256 } = input;
    if (!UUID.test(prepared_id ?? '') || !SHA256.test(manifest_sha256 ?? '')) fail('ERR_INVALID', 'Entrada de resolve inválida.');
    const delegated_identity = auth.delegated_identity;
    if (!isPlainObject(delegated_identity)) fail('ERR_FORBIDDEN', 'Identidade delegada ausente.');
    const delegatedMatches = delegated_identity.audience === 'pocketwiki.context.v1'
      && delegated_identity.principal_id === auth.principal_id
      && delegated_identity.environment_id === auth.environment_id
      && delegated_identity.thread_id === auth.thread_id
      && Array.isArray(delegated_identity.scopes)
      && delegated_identity.scopes.includes('context.read');
    if (!delegatedMatches) fail('ERR_FORBIDDEN', 'Identidade delegada não corresponde ao contexto.');
    this._collectExpired();
    const prepared = this.state.prepared.find((item) => item.prepared_id === prepared_id);
    if (!prepared) fail('ERR_CONTEXT_STALE', 'Contexto indisponível ou expirado.');
    if (prepared.owner !== ownerKey(auth)) fail('ERR_FORBIDDEN', 'Contexto pertence a outra identidade.');
    if (prepared.manifest_sha256 !== manifest_sha256) fail('ERR_CONTEXT_STALE', 'Hash de manifesto diferente.');
    if (prepared.expired || (prepared.expires_at_ms <= this.now() && prepared.pins.length === 0)) fail('ERR_CONTEXT_STALE', 'Contexto expirado.');
    return {
      context: {
        prepared_id: prepared.prepared_id, environment_id: prepared.environment_id, thread_id: prepared.thread_id,
        principal_id: prepared.principal_id, text: prepared.text, manifest: structuredClone(prepared.manifest),
        segments: structuredClone(prepared.segments), manifest_sha256: prepared.manifest_sha256, expires_at_ms: prepared.expires_at_ms
      }
    };
  }
}
