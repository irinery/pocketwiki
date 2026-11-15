import { createHash, randomUUID } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SHA1 = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const STATES = new Set(['ready', 'degraded', 'unavailable', 'incompatible']);
// Values rendered in reports are controlled by this module, never by a probe.
const COMPONENTS = new Set(['runtime', 'store', 'bridge', 'middlewareauth']);
const CODES = new Set(['OK', 'UNAVAILABLE', 'TIMEOUT', 'INCOMPATIBLE', 'AUTH_INVALID', 'DEGRADED']);
const hasOnly = (v, keys) => v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).every(k => keys.includes(k));
const integer = n => Number.isSafeInteger(n) && n >= 0;
const failure = code => Object.assign(new Error(code), { code });
const bytes = value => Buffer.byteLength(JSON.stringify(value));
const digest = value => createHash('sha256').update(value).digest('hex');

/** Domain facade. Ports are mandatory; callers must supply authenticated identity,
 * authorized sources, durable report storage, and ledger-backed export separately. */
export class DiagnosticsService {
  constructor({ authorize, probe, reports, exportCommand, buildRef, protocolMajor = 1, protocolMinor = 0 } = {}) {
    this.authorize = authorize; this.probe = probe; this.reports = reports;
    this.exportCommand = exportCommand; this.buildRef = buildRef;
    this.major = protocolMajor; this.minor = protocolMinor;
  }
  async snapshot(identity, input, negotiatedMajor = 1) {
    if (!hasOnly(input, ['environment_id', 'run_id', 'include_logs', 'max_bytes']) ||
        !UUID.test(input.environment_id ?? '') || (input.run_id !== undefined && !UUID.test(input.run_id)) ||
        typeof input.include_logs !== 'boolean' || !Number.isSafeInteger(input.max_bytes)) throw failure('ERR_INVALID');
    if (input.max_bytes < 1024 || input.max_bytes > 1048576) throw failure('ERR_REPORT_LIMIT');
    if (negotiatedMajor !== this.major) throw failure('ERR_INCOMPATIBLE');
    if (!SHA1.test(this.buildRef ?? '') || !integer(this.major) || !integer(this.minor) ||
        typeof this.authorize !== 'function' || typeof this.probe !== 'function' ||
        typeof this.reports?.save !== 'function') throw failure('ERR_UNAVAILABLE');
    let allowed;
    try { allowed = await this.authorize(identity, input.environment_id, input.run_id, 'read'); }
    catch { throw failure('ERR_UNAVAILABLE'); }
    if (allowed !== true) throw failure('ERR_FORBIDDEN');
    let source;
    const controller = new AbortController();
    let timer;
    try {
      source = await Promise.race([
        this.probe({ environment_id: input.environment_id, run_id: input.run_id, signal: controller.signal }),
        new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(failure('ERR_TIMEOUT')); }, 5000); }),
      ]);
    } catch (error) {
      if (error?.code === 'ERR_TIMEOUT') throw failure('ERR_TIMEOUT');
      throw failure('ERR_COMPONENT_UNAVAILABLE');
    } finally { clearTimeout(timer); }
    if (!source || !Array.isArray(source.components) || !Array.isArray(source.correlation_ids)) throw failure('ERR_COMPONENT_UNAVAILABLE');
    const components = [];
    const seen = new Set();
    for (const item of source.components) {
      if (!COMPONENTS.has(item?.component_id) || seen.has(item.component_id) || !STATES.has(item.state) || !CODES.has(item.code) ||
          (item.last_event_seq !== undefined && !integer(item.last_event_seq))) throw failure('ERR_COMPONENT_UNAVAILABLE');
      seen.add(item.component_id);
      const c = { component_id: item.component_id, state: item.state, code: item.code };
      if (item.last_event_seq !== undefined) c.last_event_seq = item.last_event_seq;
      components.push(c);
    }
    if (source.correlation_ids.some(id => !UUID.test(id))) throw failure('ERR_COMPONENT_UNAVAILABLE');
    let truncated = input.include_logs || source.correlation_ids.length > 100 || components.length > 100;
    const report = { protocol_major: this.major, protocol_minor: this.minor, build_ref: this.buildRef,
      components: components.slice(0, 100), correlation_ids: source.correlation_ids.slice(0, 100) };
    while (bytes(report) > input.max_bytes && report.correlation_ids.length) { report.correlation_ids.pop(); truncated = true; }
    while (bytes(report) > input.max_bytes && report.components.length) { report.components.pop(); truncated = true; }
    if (bytes(report) > input.max_bytes) throw failure('ERR_REPORT_LIMIT');
    const report_id = randomUUID();
    try { await this.reports.save({ identity, environment_id: input.environment_id, run_id: input.run_id, report_id, report, truncated }); }
    catch { throw failure('ERR_UNAVAILABLE'); }
    return { report_id, report, truncated };
  }
  // A command port must enforce authorization, current preview hash, CAS and receipt
  // atomically. This facade never writes files or treats a hash as authorization.
  async export(identity, input, command) {
    if (!hasOnly(input, ['report_id', 'approval_preview_sha256']) || !UUID.test(input.report_id ?? '') || !SHA256.test(input.approval_preview_sha256 ?? '')) throw failure('ERR_INVALID');
    if (typeof this.exportCommand !== 'function') throw failure('ERR_UNAVAILABLE');
    return this.exportCommand({ identity, input, command });
  }
}
export function previewBytes(report) { return Buffer.from(JSON.stringify(report), 'utf8'); }
export function previewSHA256(report) { return digest(previewBytes(report)); }
