// Preserve only image-critical PNG chunks; strip metadata before exporting fixture evidence.
export function sanitizeRuntimeScreenshot(input, { maxWidth = 2048, maxHeight = 1024 } = {}) {
  if (!Number.isInteger(maxWidth) || maxWidth < 1 || maxWidth > 4096 || !Number.isInteger(maxHeight) || maxHeight < 1 || maxHeight > 2048) throw new Error('invalid screenshot limits');
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (!Buffer.isBuffer(input) || input.length > 8 * 1024 * 1024 || !input.subarray(0, 8).equals(signature)) throw new Error('invalid runtime screenshot PNG');
  const keep = [signature]; let position = 8, sawHeader = false, sawData = false, sawEnd = false;
  while (position < input.length) {
    if (position + 12 > input.length) throw new Error('truncated runtime screenshot PNG');
    const length = input.readUInt32BE(position), end = position + length + 12;
    if (end > input.length || end < position) throw new Error('truncated runtime screenshot PNG chunk');
    const type = input.toString('ascii', position + 4, position + 8);
    if (!/^[A-Za-z]{4}$/.test(type)) throw new Error('invalid PNG chunk type');
    const chunk = input.subarray(position + 4, end - 4);
    if (crc32(chunk) !== input.readUInt32BE(end - 4)) throw new Error('invalid runtime screenshot PNG checksum');
    if (!sawHeader && (type !== 'IHDR' || length !== 13)) throw new Error('invalid runtime screenshot header');
    if (type === 'IHDR') {
      if (sawHeader || input.readUInt32BE(position + 8) < 1 || input.readUInt32BE(position + 8) > maxWidth || input.readUInt32BE(position + 12) < 1 || input.readUInt32BE(position + 12) > maxHeight) throw new Error('runtime screenshot dimensions invalid');
      sawHeader = true;
    }
    if (type === 'IDAT') sawData = true;
    if (type === 'IEND') { if (length !== 0 || end !== input.length) throw new Error('invalid runtime screenshot end'); sawEnd = true; }
    if (['IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS'].includes(type)) keep.push(input.subarray(position, end));
    else if (type[0] === type[0].toUpperCase()) throw new Error('unsupported critical PNG chunk');
    position = end;
  }
  if (!sawHeader || !sawData || !sawEnd) throw new Error('incomplete runtime screenshot PNG');
  return Buffer.concat(keep);
}
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
  return (crc ^ 0xffffffff) >>> 0;
}

export function runtimeScreenshotPayload(activities) {
  const matches = [];
  const name = /^nh-runtime-fallback_[0-9]+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$/i;
  function visit(value) {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { for (const item of value) visit(item); return; }
    if (Array.isArray(value.attachments)) {
      for (const attachment of value.attachments) if (name.test(attachment.name || '')) matches.push(attachment);
    }
    for (const [key, child] of Object.entries(value)) if (key !== 'attachments') visit(child);
  }
  visit(activities);
  if (matches.length !== 1 || matches[0].lifetime !== 'keepAlways' || typeof matches[0].payloadId !== 'string' || matches[0].payloadId.length > 1024 || !/^0~[A-Za-z0-9_-]{10,}={0,2}$/.test(matches[0].payloadId)) throw new Error('screenshot do slot ausente ou ambíguo');
  return matches[0].payloadId;
}
