import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runtimeFrames } from '../../../src/harness-ui/runtime/sse.mjs';
const response = chunks => new Response(new ReadableStream({ start(c) { for (const chunk of chunks) c.enqueue(new TextEncoder().encode(chunk)); c.close(); } }));
test('consome frames fragmentados e CRLF', async () => {
  const frames = [];
  for await (const frame of runtimeFrames(response(['id: 1\r\ndata: {"s', 'eq":1}\r\n\r\n']))) frames.push(frame);
  assert.deepEqual(frames, [{ seq: 1 }]);
});
test('recusa id divergente e frame incompleto', async () => {
  for (const body of ['id: 2\ndata: {"seq":1}\n\n', 'id: 1\ndata: {"seq":1}\n']) {
    await assert.rejects(async () => { for await (const frame of runtimeFrames(response([body]))) void frame; });
  }
});
