import { ComposerService } from '../../../src/harness/composer/index.mjs';
const service = new ComposerService({ dataDir: process.argv[2] });
const keepAlive = setInterval(() => {}, 1000);
try { await service._runLocked(() => new Promise(() => process.stdout.write('locked\n'))); }
finally { clearInterval(keepAlive); }
