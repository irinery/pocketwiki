import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RuntimeProjection } from '../../../src/harness-ui/runtime/projection.mjs';
const id = '11111111-1111-4111-8111-111111111111';
const id2 = '22222222-2222-4222-8222-222222222222';
const page = { module: 'runtime', data: { snapshot_id: id, revision: 1, as_of_seq: 10, receipts: [], effects: [] } };
const event = seq => ({ protocol_major: 1, event_id: id2, environment_id: id, thread_id: id, seq, committed_at_ms: 1, module: 'runtime', delivery: 'inline', payload: { entity_type: 'EffectRecord', entity_key: JSON.stringify(id2), change: 'upsert', value: { effect_id: id2, command_id: id, state: 'succeeded' } } });
test('replay ignora boundary e aplica seguinte uma vez', () => {
  const p = new RuntimeProjection({ environmentId: id, threadId: id }); p.appendPage(page);
  p.bufferEvent(event(9)); p.bufferEvent(event(10)); p.bufferEvent(event(11)); p.bufferEvent({ seq: 11, ...event(11) });
  const view = p.finish(); assert.equal(view.lastSeq, 11); assert.equal(view.effects.size, 1);
});
test('versão incompatível não publica alteração', () => {
  const p = new RuntimeProjection({ environmentId: id, threadId: id }); p.appendPage(page);
  assert.throws(() => p.bufferEvent({ ...event(11), protocol_major: 2 }), { code: 'ERR_INCOMPATIBLE' });
  assert.throws(() => p.finish(), { code: 'ERR_INVALID' });
});

test('ack aceito não é apresentado como concluído', async () => {
  const { receiptPresentation } = await import('../../../src/harness-ui/runtime/presentation.mjs');
  assert.deepEqual(receiptPresentation({ command_id: id, state: 'accepted' }), { commandId: id, label: 'Aceito', completed: false });
});

 test('overflow invalida toda a montagem', () => {
  const p = new RuntimeProjection({ environmentId: id, threadId: id }); p.appendPage(page);
  p.bytes = 4_194_304;
  assert.throws(() => p.bufferEvent(event(11)), { code: 'ERR_INVALID' });
  assert.throws(() => p.finish(), { code: 'ERR_INVALID' });
});
