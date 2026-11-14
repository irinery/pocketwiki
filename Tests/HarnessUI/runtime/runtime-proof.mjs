// The hook proof binds the specific XCTest run to the checked-out tree.
export function requireRuntimeProof(proof, { nonce, pocketwikiSHA }) {
  const keys = ['legacy_capability_status', 'nonce', 'pocketwiki_sha', 'runtime_fallback_verified', 'skipped_tests'];
  if (!proof || typeof proof !== 'object' || Array.isArray(proof) || Object.keys(proof).sort().join(',') !== keys.join(',') ||
      proof.nonce !== nonce || proof.pocketwiki_sha !== pocketwikiSHA || proof.runtime_fallback_verified !== true ||
      proof.legacy_capability_status !== 404 || proof.skipped_tests !== 0) throw new Error('prova do hook nativo ausente ou inválida');
}

export function requireRuntimeScreenshot(data, { maxHeight = 1024 } = {}) {
  if (!Number.isInteger(maxHeight) || maxHeight < 1 || maxHeight > 2048) throw new Error('limite de captura inválido');
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const end = Buffer.from([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
  if (!Buffer.isBuffer(data) || data.length < 45 || data.length > 10 * 1024 * 1024 ||
      !data.subarray(0, 8).equals(signature) || data.readUInt32BE(8) !== 13 || data.toString('ascii', 12, 16) !== 'IHDR' ||
      data.readUInt32BE(16) < 1 || data.readUInt32BE(16) > 4096 || data.readUInt32BE(20) < 1 || data.readUInt32BE(20) > maxHeight ||
      !data.subarray(-12).equals(end)) throw new Error('captura do slot inválida');
  const allowed = new Set(['IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS']);
  let offset = 8, imageData = false, finished = false;
  while (offset < data.length) {
    if (offset + 12 > data.length) throw new Error('PNG truncado');
    const length = data.readUInt32BE(offset), type = data.toString('ascii', offset + 4, offset + 8);
    if (!allowed.has(type) || offset + length + 12 > data.length) throw new Error('PNG contém metadados ou chunk inválido');
    if (type === 'IDAT') imageData = true;
    if (type === 'IEND') { if (length !== 0 || offset + 12 !== data.length) throw new Error('PNG inválido'); finished = true; }
    offset += length + 12;
  }
  if (!finished || !imageData) throw new Error('PNG incompleto');
}
