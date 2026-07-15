#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="PocketWikiMac"
APP_NAME="PocketWiki"
BUNDLE_ID="${POCKETWIKI_BUNDLE_ID:-com.irinery.PocketWikiMac}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/script"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_WEB="$APP_RESOURCES/Web"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# shellcheck source=script/signing.sh
. "$SCRIPT_DIR/signing.sh"
load_env_file "$ROOT_DIR/.env"
load_env_file "$ROOT_DIR/.env.local"
BUNDLE_ID="${POCKETWIKI_BUNDLE_ID:-$BUNDLE_ID}"

MODE="run"
SIGN_MODE="${POCKETWIKI_SIGN_MODE:-auto}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)
      SIGN_MODE="${2:-}"
      shift 2
      ;;
    run|--bundle|bundle|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$1"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify] [--sign auto|adhoc|<identity-hash>]" >&2
      exit 2
      ;;
    *)
      echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify] [--sign auto|adhoc|<identity-hash>]" >&2
      exit 2
      ;;
  esac
done

[ "${POCKETWIKI_SKIP_SECRET_SCAN:-0}" = "1" ] || "$SCRIPT_DIR/scan_secrets.sh" >/dev/null
SIGNING_IDENTITY="$(require_signing_identity "$SIGN_MODE")"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

npm --prefix "$ROOT_DIR" run build:excalidraw
npm --prefix "$ROOT_DIR" run build:graph-view
swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE" "$DIST_DIR/$PRODUCT_NAME.app"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_WEB"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

BUILD_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
RESOURCE_BUNDLE="$BUILD_DIR/PocketWikiMac_PocketWikiMac.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  ditto --noextattr --norsrc "$RESOURCE_BUNDLE" "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
fi
if [ -f "$ROOT_DIR/Sources/PocketWikiMac/Resources/PocketWikiMac.icns" ]; then
  cp "$ROOT_DIR/Sources/PocketWikiMac/Resources/PocketWikiMac.icns" "$APP_RESOURCES/PocketWikiMac.icns"
fi
for file in wiki-cockpit.html offline.html manifest.webmanifest sw.js favicon.ico favicon.png; do
  if [ -f "$ROOT_DIR/$file" ]; then
    cp "$ROOT_DIR/$file" "$APP_WEB/$file"
  fi
done
if [ -d "$ROOT_DIR/assets" ]; then
  ditto --noextattr --norsrc "$ROOT_DIR/assets" "$APP_WEB/assets"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>PocketWikiMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PocketWiki publica e acessa servidores locais na sua rede.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_http._tcp</string>
  </array>
  <key>NSHumanReadableCopyright</key>
  <string>PocketWiki local app</string>
  <key>PocketWikiRootPath</key>
  <string>$ROOT_DIR</string>
  <key>PocketWikiEnvPath</key>
  <string>$ROOT_DIR/.env</string>
</dict>
</plist>
PLIST

codesign_app_bundle "$APP_BUNDLE" "$BUNDLE_ID" "$SIGNING_IDENTITY"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --bundle|bundle)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
