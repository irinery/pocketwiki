import test from 'node:test';
import assert from 'node:assert/strict';
import { assertRuntimeProof } from './MacOSHost/runtime-proof.mjs';
const nonce = 'a'.repeat(64);
const passed = { result: 'Passed', passedTests: 1, failedTests: 0, skippedTests: 0, expectedFailures: 0 };
test('runtime proof rejects old host, stale nonce and incomplete XCTest', () => {
  assert.doesNotThrow(() => assertRuntimeProof({ marker: nonce, nonce, summary: passed }));
  for (const input of [
    { marker: '', nonce, summary: passed },
    { marker: 'b'.repeat(64), nonce, summary: passed },
    { marker: nonce, nonce, summary: { ...passed, skippedTests: 1 } },
    { marker: nonce, nonce, summary: { ...passed, failedTests: 1 } },
    { marker: nonce, nonce, summary: { ...passed, expectedFailures: 1 } },
    { marker: nonce, nonce, summary: { ...passed, passedTests: 0 } },
    { marker: nonce, nonce, summary: {} }
  ]) assert.throws(() => assertRuntimeProof(input), /prova do slot/);
});
