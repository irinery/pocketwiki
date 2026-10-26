#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
validation_dir=$(mktemp -d)
trap 'rm -rf "$validation_dir"' EXIT HUP INT TERM
swiftc -swift-version 6 Sources/PocketWikiMac/Services/PocketMemoryStore.swift Tests/pocket-memory-validation.swift -o "$validation_dir/pocket-memory-validation"
"$validation_dir/pocket-memory-validation"
