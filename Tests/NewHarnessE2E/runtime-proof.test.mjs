import test from 'node:test';
import assert from 'node:assert/strict';
import { assertRuntimeProof, runtimeProofExitCode } from './MacOSHost/runtime-proof.mjs';
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

test('host removes stale proof before rejecting unavailable Xcode', async t => {
  const { mkdtemp, writeFile, access, rm } = await import('node:fs/promises');
  const { spawnSync } = await import('node:child_process');
  const { default: os } = await import('node:os');
  const { default: path } = await import('node:path');
  const dir = await mkdtemp(path.join(os.tmpdir(), 'nh-runtime-stale-proof-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const bundle = path.join(dir, 'test.xcresult');
  await writeFile(bundle + '.runtime-proof.json', JSON.stringify({ nonce, pocketwiki_sha: 'a'.repeat(40), runtime_fallback_verified: true, legacy_capability_status: 404, skipped_tests: 0 }));
  const result = spawnSync(process.execPath, ['Tests/NewHarnessE2E/MacOSHost/run.mjs', '--result-bundle-path', bundle], { env: { ...process.env, NH_RUNTIME_LEGACY_UI: '1', POCKETWIKI_XCODE_DEVELOPER_DIR: '/nh-test-xcode-absent' }, encoding: 'utf8' });
  assert.equal(result.status, 2);
  await assert.rejects(access(bundle + '.runtime-proof.json'), { code: 'ENOENT' });
});


test('successful XCTest without a verified result bundle fails closed', () => {
  assert.equal(runtimeProofExitCode(0, true, false), 1);
  assert.equal(runtimeProofExitCode(0, true, true), 0);
  assert.equal(runtimeProofExitCode(2, true, false), 2);
  assert.equal(runtimeProofExitCode(0, false, false), 0);
});
