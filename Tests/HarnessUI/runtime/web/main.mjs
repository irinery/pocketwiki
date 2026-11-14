import { RuntimeTransport } from '../../../../src/harness/runtime/transport.mjs';
import { RuntimeClient } from '../../../../src/harness-ui/runtime/client.mjs';
import { mountRuntimePanel } from '../../../../src/harness-ui/runtime/panel.mjs';

export function mount({ bearer, environmentId, threadId, schemaSHA256 }) {
  const transport = new RuntimeTransport({ baseURL: location.origin, bearer, fetchImpl: globalThis.fetch.bind(globalThis) });
  const client = new RuntimeClient({ transport, environmentId, threadId, schemaSHA256 });
  const panel = mountRuntimePanel(document.querySelector('#runtime-slot'), client);
  return { client, panel };
}
