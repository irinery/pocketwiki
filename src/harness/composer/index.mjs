import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID } from 'node:crypto';
import { hostname } from 'node:os';
import { closeSync, fsyncSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { ComposerCommandService } from './command.mjs';
import { fail } from './service.mjs';

const transaction = new AsyncLocalStorage();
const methods = ['executeCommand', 'stage', 'saveDraft', 'getDraft', 'snapshot', 'eventsSince', 'previewFile', 'previewQuote', 'readQuote', 'removeReference', 'prepare', 'manifest', 'pin', 'resolve'];

// Lock files are installed atomically with complete owner metadata. Recovery is
// serialized; ambiguous owners and foreign hosts fail closed.
function recoverDeadOwner(lock) {
  const reaper = `${lock}.reaper`;
  try { mkdirSync(reaper, { mode: 0o700 }); } catch { return false; }
  try {
    const stat = lstatSync(lock);
    if (!stat.isFile() || stat.isSymbolicLink()) return false;
    const owner = JSON.parse(readFileSync(lock, 'utf8'));
    if (owner.host !== hostname() || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) return false;
    try { process.kill(owner.pid, 0); return false; }
    catch (error) { if (error.code !== 'ESRCH') return false; }
    const current = lstatSync(lock);
    if (current.dev !== stat.dev || current.ino !== stat.ino) return false;
    unlinkSync(lock);
    return true;
  } catch { return false; }
  finally { try { rmdirSync(reaper); } catch {} }
}
function acquire(lock) {
  const candidate = `${lock}.${process.pid}.${randomUUID()}`;
  let fd;
  try {
    fd = openSync(candidate, 'wx', 0o600);
    writeFileSync(fd, JSON.stringify({ pid: process.pid, host: hostname() }));
    fsyncSync(fd);
    closeSync(fd); fd = undefined;
    for (let attempt = 0; attempt < 2; attempt++) {
      try { linkSync(candidate, lock); return; }
      catch (error) { if (error.code !== 'EEXIST' || !recoverDeadOwner(lock)) break; }
    }
    fail('ERR_UNAVAILABLE', 'Store ocupado ou requer recuperação.');
  } catch (error) {
    if (error?.code === 'ERR_UNAVAILABLE') throw error;
    fail('ERR_UNAVAILABLE', 'Não foi possível obter lock do store.');
  } finally {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(candidate); } catch {}
  }
}

export class ComposerService extends ComposerCommandService {
  _runLocked(fn) {
    const current = transaction.getStore();
    if (current?.service === this && current.active) return fn();
    const lock = path.join(this.dataDir, '.composer-lock');
    acquire(lock);
    const context = { service: this, active: true };
    const release = () => { context.active = false; try { unlinkSync(lock); } catch { /* fail closed on next access */ } };
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
  const implementation = ComposerCommandService.prototype[method];
  Object.defineProperty(ComposerService.prototype, method, {
    value: function (...args) { return this._runLocked(() => implementation.apply(this, args)); },
    configurable: false
  });
}
export { ComposerError, canonicalJSON, readAuthorizedFile } from './service.mjs';
