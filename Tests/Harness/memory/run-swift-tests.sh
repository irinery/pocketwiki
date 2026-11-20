#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
swiftc -swift-version 6 \
  "$ROOT/Sources/PocketWikiMac/Services/PocketMemoryStore.swift" \
  "$ROOT/Sources/PocketWikiMac/Services/Harness/Memory/PocketMemoryHarnessService.swift" \
  "$ROOT/Tests/Harness/memory/PocketMemoryHarnessValidation.swift" \
  -o "$BUILD_DIR/pocket-memory-harness-validation"
"$BUILD_DIR/pocket-memory-harness-validation"
SWIFT_MEMORY_BINARY="$BUILD_DIR/pocket-memory-harness-validation" node --test "$ROOT/Tests/Harness/memory/swift-interop.test.mjs"
