import { ComposerService } from '../../../src/harness/composer/index.mjs';
const service = new ComposerService({ dataDir: process.argv[2] });
const auth = { principal_id: '11111111-1111-4111-8111-111111111111', environment_id: '33333333-3333-4333-8333-333333333333', thread_id: '44444444-4444-4444-8444-444444444444', scopes: ['context.read'] };
const command = { protocol_major: 1, command_id: '66666666-6666-4666-8666-666666666666', environment_id: auth.environment_id, expected_revision: 0, operation: 'composer.prepare', input: { thread_id: auth.thread_id, draft_id: '55555555-5555-4555-8555-555555555555', text: 'uma vez', references: [], context_budget_bytes: 1024 } };
for (;;) {
  try { process.stdout.write(JSON.stringify(await service.executeCommand(auth, command)) + '\n'); break; }
  catch (error) { if (error.code !== 'ERR_UNAVAILABLE') throw error; await new Promise((resolve) => setTimeout(resolve, 5)); }
}

if (process.argv[3] === '--hold') setInterval(() => {}, 1000);
