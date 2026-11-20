import { ComposerService } from '../../../src/harness/composer/index.mjs';
const [dataDir, prefix] = process.argv.slice(2);
const identity = { principal_id: '11111111-1111-4111-8111-111111111111', environment_id: '33333333-3333-4333-8333-333333333333', thread_id: '44444444-4444-4444-8444-444444444444', scopes: ['context.read'] };
const service = new ComposerService({ dataDir });
for (let i = 0; i < 20; i++) {
  const draft_id = `${prefix}8888888-8888-4888-8888-${String(i).padStart(12, '0')}`;
  for (;;) {
    try { service.saveDraft(identity, { draft_id, thread_id: identity.thread_id, text: draft_id, references: [], revision: 0 }); break; }
    catch (error) {
      if (error.code !== 'ERR_UNAVAILABLE') throw error;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  }
}
