#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.build"

swiftc -parse-as-library \
  "$ROOT/Sources/PocketWikiMac/Models/Harness/HarnessV1.swift" \
  "$ROOT/Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift" \
  "$ROOT/Tests/Harness/HarnessV1CorpusRunner.swift" \
  -o "$ROOT/.build/harness-corpus"
"$ROOT/.build/harness-corpus" "$ROOT/src/harness/contracts/corpus-v1.json"
