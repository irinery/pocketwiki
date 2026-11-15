import { readFile } from 'node:fs/promises';
import { MemoryHarnessService } from '../../../src/harness/memory/service.mjs';
const [root, input] = process.argv.slice(2);
const auth = { principal_id:'50000000-0000-4000-8000-000000000001', environment_id:'10000000-0000-4000-8000-000000000001', aggregate_id:'20000000-0000-4000-8000-000000000001', thread_id:'30000000-0000-4000-8000-000000000001', scopes:['context.read', 'memory.write', 'memory.personal.read'] };
const namespace = { environment_id:auth.environment_id, project_id:auth.aggregate_id, thread_id:auth.thread_id, schema_version:2, note_revision:0 };
process.send('ready');
process.on('message', async (message) => {
  if (message !== 'go') return;
  try {
    const content = await readFile(input, 'utf8');
    await new MemoryHarnessService({ root, policy:async () => true, association:async () => true }).importNamespace(auth, { namespace, content });
    process.send('completed');
  } catch (error) { process.send(error.code || 'unexpected'); }
  process.disconnect();
});
