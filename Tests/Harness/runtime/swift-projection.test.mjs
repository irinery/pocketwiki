import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
test('Swift monta snapshot e rejeita referência, boundary e entidade inconsistentes', () => {
  const dir = mkdtempSync(join(tmpdir(), 'runtime-projection-'));
  try {
    const bin = join(dir, 'test');
    const compile = spawnSync('swiftc', ['-swift-version', '6', 'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift', 'Sources/PocketWikiMac/Models/Harness/HarnessV1.swift', 'Sources/PocketWikiMac/Services/Harness/Runtime/RuntimeProjection.swift', 'Tests/Harness/runtime/SwiftProjectionTest.swift', '-o', bin], { encoding: 'utf8' });
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(bin, [], { encoding: 'utf8' }); assert.equal(run.status, 0, run.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
