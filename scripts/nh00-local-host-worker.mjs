import { KernelLocalBootstrapClient } from '../src/harness/kernel-bootstrap.mjs';
import { LocalCredentialHost } from '../src/harness/local-host.mjs';
import { rename } from 'node:fs/promises';

const hosts = new Map();
const deliveries = new Map();

process.on('message', async (message) => {
  if (!message || typeof message.id !== 'string') return;
  if (message.method === 'deliveryAck') {
    deliveries.get(message.id)?.();
    return;
  }
  try {
    if (message.method === 'issue') {
      const config = message.config;
      const kernel = new KernelLocalBootstrapClient({ socketPath: config.socketPath });
      if (config.grant) await kernel.registerAggregateGrant(config.grant);
      const host = new LocalCredentialHost({
        principalId: config.principalId,
        environmentId: config.environmentId,
        audience: config.audience,
        grantedScopes: config.grantedScopes,
        persistVerifier: (verifier) => kernel.persistVerifier(verifier),
        deliverBearer: async ({ bearer }) => {
          await new Promise((resolve, reject) => {
            const timer = setTimeout(() => { deliveries.delete(message.id); reject(new Error('delivery ACK timed out')); }, 3000);
            deliveries.set(message.id, () => { clearTimeout(timer); deliveries.delete(message.id); resolve(); });
            process.send({ id: message.id, type: 'bearer', bearer }, (error) => {
              if (error) { clearTimeout(timer); deliveries.delete(message.id); reject(error); }
            });
          });
          if (config.disconnectBeforeDeliveryFailure) await rename(config.socketPath, `${config.socketPath}.offline`);
          if (config.failDelivery) throw new Error('injected private process channel failure');
        },
        now: config.nowMS === undefined ? () => Date.now() : () => config.nowMS
      });
      try {
        const metadata = await host.bootstrap(config.requestedScopes, { aggregateId: config.aggregateId });
        hosts.set(message.id, host);
        process.send({ id: message.id, type: 'complete', metadata });
      } catch (error) {
        process.send({ id: message.id, type: 'complete', error: error.code ?? 'ERR_DELIVERY' });
      }
      return;
    }
    if (message.method === 'revoke') {
      const host = hosts.get(message.hostId);
      const revoked = host ? await host.revoke(message.bearer) : false;
      process.send({ id: message.id, type: 'complete', revoked });
      return;
    }
    process.send({ id: message.id, type: 'complete', error: 'ERR_INVALID' });
  } catch {
    process.send({ id: message.id, type: 'complete', error: 'ERR_INTERNAL' });
  }
});

process.send({ type: 'ready' });
