import { RuntimeTransport } from '../../../../src/harness/runtime/transport.mjs';
import { RuntimeClient } from '../../../../src/harness-ui/runtime/client.mjs';
import { mountRuntimePanel } from '../../../../src/harness-ui/runtime/panel.mjs';

export function mount({ bearer, environmentId, threadId, schemaSHA256, commandIds }) {
  const transport = new RuntimeTransport({ baseURL: location.origin, bearer, fetchImpl: globalThis.fetch.bind(globalThis) });
  let next = 0;
  const newCommandId = commandIds ? () => {
    if (next >= commandIds.length) throw new Error('IDs de fixture esgotados');
    return commandIds[next++];
  } : undefined;
  const client = new RuntimeClient({ transport, environmentId, threadId, schemaSHA256, ...(newCommandId ? { newCommandId } : {}) });
  const panel = mountRuntimePanel(document.querySelector('#runtime-slot'), client);
  return { client, panel };
}
