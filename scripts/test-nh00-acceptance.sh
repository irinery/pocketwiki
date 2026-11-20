#!/bin/sh
set -eu
NH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$NH_ROOT"
mkdir -p .build
NH_CORPUS=$(mktemp "$NH_ROOT/.build/nh00-acceptance.XXXXXX.json")
trap 'rm -f "$NH_CORPUS"' EXIT HUP INT TERM
node --input-type=module - "$NH_CORPUS" <<'JS'
import {readFileSync, writeFileSync} from 'node:fs';
const shared = JSON.parse(readFileSync('src/harness/contracts/corpus-v1.json', 'utf8'));
const independent = JSON.parse(readFileSync('Tests/Harness/nh00-acceptance-regressions.json', 'utf8'));
const ids = new Set();
for (const slot of [...shared.slots, ...independent.slots]) {
  if (ids.has(slot.id)) throw new Error(`duplicate corpus id: ${slot.id}`);
  ids.add(slot.id);
}
writeFileSync(process.argv[2], `${JSON.stringify({slots: [...shared.slots, ...independent.slots]})}\n`);
console.log(`Combined corpus: ${ids.size} unique slots`);
JS
NH_JS_STATUS=0
NH_CORPUS="$NH_CORPUS" node --input-type=module <<'JS' || NH_JS_STATUS=$?
import {readFileSync} from 'node:fs';
import {validateAgainst} from './src/harness/contracts/validate.mjs';
const {slots} = JSON.parse(readFileSync(process.env.NH_CORPUS,'utf8'));
let failures = 0;
for (const c of slots) {
  const result = validateAgainst(c.schema,c.value,c.operation);
  console.log(JSON.stringify({id:c.id,runtime:'js',expected:c.accept,actual:result.valid}));
  if (result.valid !== c.accept) failures++;
}
if (failures) process.exit(1);
JS
swiftc -parse-as-library \
 Sources/PocketWikiMac/Models/Harness/HarnessV1.swift \
 Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift \
 Tests/Harness/HarnessV1CorpusRunner.swift -o .build/nh00-acceptance-corpus
NH_SWIFT_STATUS=0
.build/nh00-acceptance-corpus "$NH_CORPUS" src/harness/contracts/harness-v1.schema.json || NH_SWIFT_STATUS=$?
[ "$NH_JS_STATUS" -eq 0 ] && [ "$NH_SWIFT_STATUS" -eq 0 ]
