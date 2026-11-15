import { AsyncLocalStorage } from 'node:async_hooks';
import { mkdirSync, rmdirSync } from 'node:fs';
import path from 'node:path';
import { ComposerContextService } from './retention.mjs';
import { fail } from './service.mjs';

const transaction = new AsyncLocalStorage();
const methods = ['stage', 'saveDraft', 'getDraft', 'snapshot', 'eventsSince', 'previewFile', 'removeReference', 'prepare', 'manifest', 'pin', 'resolve'];

// One writer/reader at a time across processes. A crash may leave the lock
// directory behind; never guess whether it is safe to remove.
export class ComposerService extends ComposerContextService {
  _runLocked(fn) {
    const current = transaction.getStore();
    if (current?.service === this && current.active) return fn();
    const lock = path.join(this.dataDir, '.composer-lock');
    try { mkdirSync(lock, { mode: 0o700 }); }
    catch { fail('ERR_UNAVAILABLE', 'Store ocupado ou requer recuperação.'); }
    const context = { service: this, active: true };
    const release = () => { context.active = false; try { rmdirSync(lock); } catch { /* fail closed on next access */ } };
    try {
      this._reload();
      const result = transaction.run(context, fn);
      if (result && typeof result.then === 'function') return result.finally(release);
      release();
      return result;
    } catch (error) { release(); throw error; }
  }
}
for (const method of methods) {
  const implementation = ComposerContextService.prototype[method];
  Object.defineProperty(ComposerService.prototype, method, {
    value: function (...args) { return this._runLocked(() => implementation.apply(this, args)); },
    configurable: false
  });
}
export { ComposerError, canonicalJSON, readAuthorizedFile } from './service.mjs';
