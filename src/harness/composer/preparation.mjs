import { ComposerError, ComposerService, canonicalJSON, digest, fail, isPlainObject, MIME_LIMITS, ownerKey, PREPARED_TTL_MS, readAuthorizedFile, UUID, validateAuth, validateReference, validateString } from './service.mjs';

export class ComposerPreparationService extends ComposerService {
  async prepare(auth, input) {
    validateAuth(auth);
    if (!isPlainObject(input) || Object.keys(input).some((key) => !['thread_id', 'draft_id', 'text', 'references', 'context_budget_bytes'].includes(key))) fail('ERR_INVALID', 'Entrada de prepare inválida.');
    if (input.thread_id !== auth.thread_id || !UUID.test(input.draft_id ?? '') || !Array.isArray(input.references) || input.references.length > 20) fail('ERR_INVALID', 'Identidade ou referências inválidas.');
    const textBytes = validateString(input.text, 1, 32768, 'Texto da mensagem');
    if (!Number.isSafeInteger(input.context_budget_bytes) || input.context_budget_bytes < 1024 || input.context_budget_bytes > 65536) fail('ERR_INVALID', 'context_budget_bytes fora do limite.');
    input.references.forEach(validateReference);
    const key = ownerKey(auth);
    this._collectExpired();
    const draft = this.state.drafts.find((item) => item.owner === key && item.draft_id === input.draft_id);
    if (!draft) fail('ERR_CONTEXT_STALE', 'Draft indisponível ou expirado.');
    if (draft.text !== input.text || input.references.some((reference) => !draft.references.some((saved) => JSON.stringify(saved) === JSON.stringify(reference)))) fail('ERR_CONTEXT_STALE', 'O draft mudou desde a última revisão salva.');

    const segments = [];
    const manifest = [];
    let includedBytes = textBytes;
    const stagedById = new Map(this.state.staging.filter((item) => item.owner === key && item.expires_at_ms > this.now()).map((item) => [item.reference.reference_id, item]));
    for (const reference of input.references) {
      let bytes;
      let mime;
      if (stagedById.has(reference.reference_id)) {
        const staged = stagedById.get(reference.reference_id);
        bytes = Buffer.from(staged.content_base64, 'base64');
        mime = staged.mime;
      } else {
        let resolved;
        try {
          if (this.state.sources.some((item) => item.owner === key && item.reference_id === reference.reference_id) && reference.relative_path) {
            const root = this.state.sources.find((item) => item.owner === key && item.reference_id === reference.reference_id).root;
            this.authorizeRoot(auth, root);
            bytes = await readAuthorizedFile(root, reference.relative_path);
            mime = reference.kind === 'image' ? 'image/png' : 'text/plain';
          } else if (this.sourceResolver) resolved = await this.sourceResolver(structuredClone(reference), structuredClone(auth));
          else fail('ERR_CONTEXT_STALE', 'A fonte selecionada não está disponível.');
          if (resolved !== undefined) {
            bytes = Buffer.from(resolved.bytes ?? []);
            mime = resolved.mime ?? (reference.kind === 'image' ? 'image/png' : 'text/plain');
            if (resolved.relative_path !== undefined && reference.relative_path !== resolved.relative_path) fail('ERR_CONTEXT_STALE', 'A origem da referência mudou.');
          }
        } catch (error) {
          if (error instanceof ComposerError) throw error;
          fail('ERR_CONTEXT_STALE', 'A fonte selecionada não pôde ser lida.');
        }
      }
      if (bytes.byteLength !== reference.size_bytes || digest(bytes) !== reference.sha256) fail('ERR_CONTEXT_STALE', 'A fonte mudou desde o preview.');
      if (!Object.hasOwn(MIME_LIMITS, mime) || bytes.byteLength > MIME_LIMITS[mime]) fail('ERR_UNSUPPORTED', 'MIME ou tamanho não permitido para esta referência.');
      if (!mime.startsWith('image/')) {
        const text = bytes.toString('utf8');
        if (!Buffer.from(text, 'utf8').equals(bytes)) fail('ERR_UNSUPPORTED', 'Referência textual não é UTF-8 válido.');
      }
      includedBytes += bytes.byteLength;
      if (includedBytes > input.context_budget_bytes || includedBytes > 4 * 1024 * 1024) fail('ERR_BUDGET', 'O contexto selecionado excede o orçamento; remova referências e prepare de novo.');
      manifest.push(structuredClone(reference));
      segments.push({ reference_id: reference.reference_id, kind: reference.kind, mime, content_base64: bytes.toString('base64'), sha256: reference.sha256, trust: 'untrusted_content' });
    }
    const manifestSha256 = digest(Buffer.from(canonicalJSON({ environment_id: auth.environment_id, thread_id: auth.thread_id, principal_id: auth.principal_id, text: input.text, manifest }), 'utf8'));
    const prepared = {
      prepared_id: this.id(), environment_id: auth.environment_id, thread_id: auth.thread_id, principal_id: auth.principal_id,
      text: input.text, manifest, segments, manifest_sha256: manifestSha256,
      included_bytes: includedBytes, created_at_ms: this.now(), expires_at_ms: this.now() + PREPARED_TTL_MS,
      pins: [], owner: key
    };
    this.state.prepared.push(prepared);
    this._persist();
    return { prepared_id: prepared.prepared_id, manifest: structuredClone(manifest), included_bytes: includedBytes, manifest_sha256: manifestSha256, expires_at_ms: prepared.expires_at_ms };
  }

  manifest(auth, preparedId) {
    validateAuth(auth);
    if (!UUID.test(preparedId ?? '')) fail('ERR_INVALID', 'prepared_id inválido.');
    this._collectExpired();
    const prepared = this.state.prepared.find((item) => item.prepared_id === preparedId && item.owner === ownerKey(auth));
    if (!prepared || prepared.expired) fail('ERR_CONTEXT_STALE', 'Manifesto indisponível ou expirado.');
    return { manifest: structuredClone(prepared.manifest), included_bytes: prepared.included_bytes, manifest_sha256: prepared.manifest_sha256, expires_at_ms: prepared.expires_at_ms };
  }
}
