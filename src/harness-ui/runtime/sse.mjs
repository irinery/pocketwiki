// Parse bounded, complete SSE frames; envelope validation remains in projection.
export async function* runtimeFrames(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = '', data = [], id, frameBytes = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      pending += decoder.decode(value || new Uint8Array(), { stream: !done });
      for (;;) {
        const at = pending.indexOf('\n'); if (at < 0) break;
        let line = pending.slice(0, at); pending = pending.slice(at + 1);
        frameBytes += new TextEncoder().encode(line).length + 1;
        if (frameBytes > 262144) throw new Error('SSE frame exceeds limit');
        if (line.endsWith('\r')) line = line.slice(0, -1);
        if (!line) {
          if (data.length) {
            const event = JSON.parse(data.join('\n'));
            if (id !== String(event.seq)) throw new Error('SSE id mismatch');
            yield event;
          }
          data = []; id = undefined; frameBytes = 0; continue;
        }
        if (line.startsWith(':')) continue;
        const split = line.indexOf(':');
        const field = split < 0 ? line : line.slice(0, split);
        let fieldValue = split < 0 ? '' : line.slice(split + 1);
        if (fieldValue.startsWith(' ')) fieldValue = fieldValue.slice(1);
        if (field === 'data') data.push(fieldValue); else if (field === 'id') id = fieldValue;
      }
      if (new TextEncoder().encode(pending).length + frameBytes > 262144) throw new Error('SSE frame exceeds limit');
      if (done) {
        if (pending || data.length) throw new Error('Incomplete SSE frame');
        return;
      }
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}
