#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/.build/core-tests"
BIN="$OUT_DIR/PocketWikiCoreTests"

mkdir -p "$OUT_DIR"

swiftc \
  "$ROOT_DIR"/Sources/PocketWikiMac/Models/*.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Support/String+PocketWiki.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Support/PocketFormatters.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Support/PocketWikiDateParser.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Support/WikiMarkdownFormatter.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Support/LocalAIResponseLinkifier.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/LocalAIEndpointPolicy.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/LocalAIRuntimeConfiguration.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/LocalAIContextBuilder.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/LMStudioClient.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/PocketWikiRouteBuilder.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/PocketWikiServerConfiguration.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/PocketWikiServerPayloads.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/ExcalidrawEditorResourceResolver.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiFilePathResolver.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/RemoteWikiClient.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiTextParser.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/ExcalidrawParser.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiIndexer.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiFolderLoader.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiAnalytics.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/WikiSidebarExplorer.swift \
  "$ROOT_DIR"/Tests/PocketWikiCoreTests/CoreTestRunner.swift \
  -o "$BIN"

"$BIN"
