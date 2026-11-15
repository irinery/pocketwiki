// Parse bounded, complete SSE frames; envelope validation remains in projection.
export async function* runtimeFrames(response, { signal, idleTimeoutMS } = {}) {
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  if (signal?.aborted) cancel(); else signal?.addEventListener('abort', cancel, { once:true });
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = '', data = [], id, frameBytes = 0;
  try {
    for (;;) {
      let timer;
      const read = reader.read();
      const timeout = idleTimeoutMS === undefined ? null : new Promise((_, reject) => { timer=setTimeout(()=>reject(new Error('SSE idle timeout')),idleTimeoutMS); });
      let value,done;
      try { ({value,done}=await (timeout ? Promise.race([read,timeout]) : read)); } finally { if(timer)clearTimeout(timer); }
      if (signal?.aborted) throw new Error('SSE aborted');
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
  } finally { signal?.removeEventListener('abort', cancel); void reader.cancel().catch(() => {}); reader.releaseLock(); }
}
