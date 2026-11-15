import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DiagnosticsService, previewBytes, previewSHA256 } from '../../../src/harness/diagnostics/service.mjs';
const env = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const input = { environment_id: env, include_logs: false, max_bytes: 1024 };
function service(extra = {}) { return new DiagnosticsService({ buildRef: 'a'.repeat(40), authorize: async () => true,
  probe: async () => ({components: [{component_id:'runtime',state:'ready',code:'OK'}, {component_id:'bridge',state:'unavailable',code:'AUTH_INVALID'}], correlation_ids: []}),
  reports: {save: async () => {}}, ...extra }); }
const rejects = (promise, code) => assert.rejects(promise, e => e.code === code);
test('runtime and authentication health are independent', async () => {
 const {report} = await service().snapshot({}, input); assert.deepEqual(report.components.map(c => c.state), ['ready', 'unavailable']);
});
test('major mismatch and absent auth/storage fail closed', async () => {
 await rejects(service().snapshot({}, input, 2), 'ERR_INCOMPATIBLE');
 await rejects(service({authorize: undefined}).snapshot({}, input), 'ERR_UNAVAILABLE');
 await rejects(service({authorize: async () => false}).snapshot({}, input), 'ERR_FORBIDDEN');
 await rejects(service({reports: undefined}).snapshot({}, input), 'ERR_UNAVAILABLE');
 await rejects(service().export({}, {report_id:id, approval_preview_sha256:'a'.repeat(64)}, {}), 'ERR_UNAVAILABLE');
});
test('report is bounded and never includes arbitrary probe data or logs', async () => {
 const secret = 'bearer-secret prompt-secret challenge-secret /Users/private/secret';
 const result = await service({probe: async () => ({components:[{component_id:'runtime',state:'ready',code:'OK', log:secret}], correlation_ids:Array(100).fill(id), logs:[secret], unknown:secret})}).snapshot({}, {...input, include_logs:true});
 const data = previewBytes(result.report); assert.ok(data.length <= input.max_bytes); assert.equal(result.truncated, true);
 assert.equal(data.includes(secret), false); assert.match(previewSHA256(result.report), /^[0-9a-f]{64}$/);
});
test('validation happens before I/O and unknown components fail closed', async () => {
 let called = false; const svc = service({authorize: async () => {called=true; return true;}});
 await rejects(svc.snapshot({}, {...input, max_bytes: 0}), 'ERR_REPORT_LIMIT'); assert.equal(called, false);
 await rejects(service({probe:async()=>({components:[{component_id:'secret', state:'ready',code:'OK'}],correlation_ids:[]})}).snapshot({},input),'ERR_COMPONENT_UNAVAILABLE');
});
test('authorization precedes every source read and failed writes do not return a report', async () => {
 let reads = 0;
 const probe = async () => { reads++; return {components: [], correlation_ids: []}; };
 await rejects(service({authorize: async () => false, probe}).snapshot({}, input), 'ERR_FORBIDDEN');
 assert.equal(reads, 0);
 await rejects(service({authorize: async () => { throw new Error('token-secret'); }, probe}).snapshot({}, input), 'ERR_UNAVAILABLE');
 assert.equal(reads, 0);
 await rejects(service({probe, reports:{save:async () => {throw new Error('private path');}}}).snapshot({}, input), 'ERR_UNAVAILABLE');
 assert.equal(reads, 1);
});
test('save receives only the sanitized report and preview hash tracks exact bytes', async () => {
 let persisted;
 const svc = service({reports:{save:async value => { persisted = structuredClone(value); }}, probe:async () => ({
  components:[{component_id:'runtime',state:'ready',code:'OK',prompt:'private prompt'}], correlation_ids:[], logs:['private token']
 })});
 const result = await svc.snapshot({}, input);
 assert.deepEqual(persisted.report, result.report);
 assert.equal(JSON.stringify(persisted.report).includes('private'), false);
 assert.notEqual(previewSHA256(result.report), previewSHA256({...result.report, protocol_minor:1}));
});
