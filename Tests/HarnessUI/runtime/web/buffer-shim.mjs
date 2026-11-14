// RuntimeTransport only needs UTF-8 byte counts and concatenation.
export const Buffer = {
  byteLength(value) { return new TextEncoder().encode(value).byteLength; },
  concat(chunks, size) {
    const result = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
    if (offset !== size) throw new RangeError('Invalid buffer size');
    return result;
  }
};
