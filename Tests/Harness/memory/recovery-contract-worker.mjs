import { inspectRecoveryFile } from '../../../src/harness/memory/recovery-contract.mjs';
process.on('message', async ({ directory, name }) => {
  process.send(await inspectRecoveryFile(directory, name), () => process.disconnect());
});
