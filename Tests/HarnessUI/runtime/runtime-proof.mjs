// The hook proof binds the specific XCTest run to the checked-out tree.
export function requireRuntimeProof(proof, { nonce, pocketwikiSHA }) {
  const keys = ['legacy_capability_status', 'nonce', 'pocketwiki_sha', 'runtime_fallback_verified', 'skipped_tests'];
  if (!proof || typeof proof !== 'object' || Array.isArray(proof) || Object.keys(proof).sort().join(',') !== keys.join(',') ||
      proof.nonce !== nonce || proof.pocketwiki_sha !== pocketwikiSHA || proof.runtime_fallback_verified !== true ||
      proof.legacy_capability_status !== 404 || proof.skipped_tests !== 0) throw new Error('prova do hook nativo ausente ou inválida');
}
