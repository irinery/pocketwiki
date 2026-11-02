#!/bin/sh
set -eu
NH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$NH_ROOT"
NH_JS_STATUS=0
node --input-type=module <<'JS' || NH_JS_STATUS=$?
import {readFileSync} from 'node:fs';
import {validateAgainst} from './src/harness/contracts/validate.mjs';
const {slots} = JSON.parse(readFileSync('Tests/Harness/nh00-acceptance-regressions.json','utf8'));
let failures = 0;
for (const c of slots) {
  const result = validateAgainst(c.schema,c.value,c.operation);
  console.log(JSON.stringify({id:c.id,runtime:'js',expected:c.accept,actual:result.valid}));
  if (result.valid !== c.accept) failures++;
}
if (failures) process.exit(1);
JS
mkdir -p .build
swiftc -parse-as-library \
 Sources/PocketWikiMac/Models/Harness/HarnessV1.swift \
 Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift \
 Tests/Harness/HarnessV1CorpusRunner.swift -o .build/nh00-acceptance-corpus
NH_SWIFT_STATUS=0
.build/nh00-acceptance-corpus Tests/Harness/nh00-acceptance-regressions.json src/harness/contracts/harness-v1.schema.json || NH_SWIFT_STATUS=$?
[ "$NH_JS_STATUS" -eq 0 ] && [ "$NH_SWIFT_STATUS" -eq 0 ]
