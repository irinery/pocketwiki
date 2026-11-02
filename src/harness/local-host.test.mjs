import test from 'node:test';
import assert from 'node:assert/strict';
import { LocalCredentialHost, LOCAL_CREDENTIAL_TTL_MS } from './local-host.mjs';

const principalId = '11111111-1111-4111-8111-111111111111';
const environmentId = '22222222-2222-4222-8222-222222222222';
const threadId = '33333333-3333-4333-8333-333333333333';

test('local bootstrap delivers a random bearer and persists only its scoped verifier', async () => {
  let delivery;
  let persisted;
  let now = 1_700_000_000_000;
  const host = new LocalCredentialHost({
    principalId, environmentId, audience: 'pocketkernel.local', grantedScopes: ['read', 'submit'],
    deliverBearer: async (message) => { delivery = message; },
    persistVerifier: async (verifier) => { persisted = verifier; },
    now: () => now
  });

  const metadata = await host.bootstrap(['submit'], { threadId });
  assert.equal(Buffer.from(delivery.bearer, 'base64url').length, 32);
  assert.deepEqual(metadata.scopes, ['submit']);
  assert.equal(metadata.expires_at_ms, now + LOCAL_CREDENTIAL_TTL_MS);
  assert.equal(persisted.token_sha256.length, 64);
  assert.equal(Object.hasOwn(persisted, 'bearer'), false);
  assert.deepEqual(host.authenticate(delivery.bearer, { audience: 'pocketkernel.local', scope: 'submit', threadId }), metadata);
  assert.throws(() => host.authenticate(delivery.bearer, { audience: 'wrong' }), { code: 'ERR_FORBIDDEN' });
  assert.throws(() => host.authenticate(delivery.bearer, { audience: 'pocketkernel.local', scope: 'execute', threadId }), { code: 'ERR_FORBIDDEN' });
  assert.equal(await host.revoke(delivery.bearer), true);
  assert.throws(() => host.authenticate(delivery.bearer, { audience: 'pocketkernel.local' }), { code: 'ERR_FORBIDDEN' });
});

test('local credential expires at the inclusive TTL boundary', async () => {
  let delivery;
  let now = 5_000;
  const host = new LocalCredentialHost({
    principalId, environmentId, audience: 'pocketkernel.local', grantedScopes: ['read'],
    deliverBearer: async (message) => { delivery = message; }, now: () => now
  });
  const metadata = await host.bootstrap(['read']);
  assert.doesNotThrow(() => host.authenticate(delivery.bearer, { audience: 'pocketkernel.local' }));
  now = metadata.expires_at_ms - 1;
  assert.doesNotThrow(() => host.authenticate(delivery.bearer, { audience: 'pocketkernel.local' }));
  now = metadata.expires_at_ms;
  assert.throws(() => host.authenticate(delivery.bearer, { audience: 'pocketkernel.local' }), { code: 'ERR_EXPIRED' });
});

test('local bootstrap refuses scopes the host did not grant', async () => {
  const host = new LocalCredentialHost({
    principalId, environmentId, audience: 'pocketkernel.local', grantedScopes: ['read'],
    deliverBearer: async () => {}
  });
  await assert.rejects(host.bootstrap(['read', 'scm.merge']), { code: 'ERR_FORBIDDEN' });
});
