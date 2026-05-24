#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/.build/integration-tests"
BIN="$OUT_DIR/PocketWikiIntegrationTests"
APP_BUNDLE="$ROOT_DIR/dist/PocketWiki.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

mkdir -p "$OUT_DIR"

swift build --package-path "$ROOT_DIR"

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
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/PocketWikiMDNSResponder.swift \
  "$ROOT_DIR"/Sources/PocketWikiMac/Services/PocketWikiHTTPServer.swift \
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
  "$ROOT_DIR"/Tests/PocketWikiIntegrationTests/BundleModuleShim.swift \
  "$ROOT_DIR"/Tests/PocketWikiIntegrationTests/IntegrationTestRunner.swift \
  -o "$BIN"

(
  cd "$ROOT_DIR"
  "$BIN"
)

"$ROOT_DIR"/script/build_and_run.sh --bundle >/dev/null

test -x "$APP_BUNDLE/Contents/MacOS/PocketWiki"
test -f "$INFO_PLIST"
test -f "$APP_BUNDLE/Contents/Resources/Web/wiki-cockpit.html"
test -f "$APP_BUNDLE/Contents/Resources/Web/assets/favicon.png"
test -f "$APP_BUNDLE/PocketWikiMac_PocketWikiMac.bundle/wiki-review.md"
test -f "$APP_BUNDLE/PocketWikiMac_PocketWikiMac.bundle/ExcalidrawEditor/index.html"
test -f "$APP_BUNDLE/PocketWikiMac_PocketWikiMac.bundle/ExcalidrawEditor/THIRD_PARTY_NOTICES.md"

plutil -extract NSLocalNetworkUsageDescription raw -o - "$INFO_PLIST" >/dev/null
plutil -extract NSBonjourServices xml1 -o - "$INFO_PLIST" | grep -q "_http._tcp"
plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw -o - "$INFO_PLIST" | grep -q "true"

echo "ok - app bundle contract"
echo "4 integration checks passing"
