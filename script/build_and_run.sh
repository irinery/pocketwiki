#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="PocketWikiMac"
APP_NAME="PocketWiki"
BUNDLE_ID="${POCKETWIKI_BUNDLE_ID:-com.irinery.PocketWikiMac}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/script"
APP_VERSION="${APP_VERSION:-$("$SCRIPT_DIR/resolve_release_version.sh" --print app_version)}"
RELEASE_TAG="${RELEASE_TAG:-$("$SCRIPT_DIR/resolve_release_version.sh" --print release_tag)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf "1")}"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf "unknown")}"
DIST_DIR="${POCKETWIKI_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_WEB="$APP_RESOURCES/Web"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_MIDDLEWARE_METADATA="$APP_RESOURCES/Addons/MiddlewareAuth"
APP_POCKETKERNEL_METADATA="$APP_RESOURCES/Addons/PocketKernel"
APP_MCP="$APP_RESOURCES/PocketWikiMCP"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# shellcheck source=script/signing.sh
. "$SCRIPT_DIR/signing.sh"
load_env_file "$ROOT_DIR/.env"
load_env_file "$ROOT_DIR/.env.local"
BUNDLE_ID="${POCKETWIKI_BUNDLE_ID:-$BUNDLE_ID}"

MODE="run"
DEFAULT_SIGN_MODE="auto"
if [ "${CI:-}" = "true" ]; then
  DEFAULT_SIGN_MODE="adhoc"
fi
SIGN_MODE="${POCKETWIKI_SIGN_MODE:-$DEFAULT_SIGN_MODE}"
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

MIDDLEWARE_AUTH_ADDON_BINARY="$ROOT_DIR/.build/middleware-auth-addon/middleware-codex-oauth"
if [ "${POCKETWIKI_INCLUDE_MIDDLEWARE_AUTH_ADDON:-1}" = "1" ]; then
  "$SCRIPT_DIR/build_middleware_auth_addon.sh" "$MIDDLEWARE_AUTH_ADDON_BINARY"
fi
POCKETKERNEL_ADDON_BINARY="$ROOT_DIR/.build/pocketkernel-addon/pocketkernel"
if [ "${POCKETWIKI_INCLUDE_POCKETKERNEL_ADDON:-1}" = "1" ]; then
  "$SCRIPT_DIR/build_pocketkernel_addon.sh" "$POCKETKERNEL_ADDON_BINARY"
fi

stop_existing_app() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1 || pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    attempt=1
    while [ "$attempt" -le 30 ]; do
      if ! pgrep -x "$APP_NAME" >/dev/null 2>&1 && ! pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
      attempt=$((attempt + 1))
    done
  fi

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

  managed_helper="$APP_BUNDLE/Contents/Helpers/middleware-codex-oauth"
  for pid in $(pgrep -x middleware-codex-oauth 2>/dev/null || true); do
    command_path="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [ "$command_path" = "$managed_helper" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done

  managed_kernel="$APP_BUNDLE/Contents/Helpers/pocketkernel"
  for pid in $(pgrep -x pocketkernel 2>/dev/null || true); do
    command_path="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command_path" in
      "$managed_kernel"|"$managed_kernel "*) kill "$pid" >/dev/null 2>&1 || true ;;
    esac
  done
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry)
    stop_existing_app
    ;;
esac

npm --prefix "$ROOT_DIR" run build:excalidraw
npm --prefix "$ROOT_DIR" run build:graph-view
swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE" "$DIST_DIR/$PRODUCT_NAME.app"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_WEB" "$APP_HELPERS" "$APP_MIDDLEWARE_METADATA" "$APP_POCKETKERNEL_METADATA" "$APP_MCP"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [ -x "$MIDDLEWARE_AUTH_ADDON_BINARY" ]; then
  cp "$MIDDLEWARE_AUTH_ADDON_BINARY" "$APP_HELPERS/middleware-codex-oauth"
  chmod 755 "$APP_HELPERS/middleware-codex-oauth"
  cp "$MIDDLEWARE_AUTH_ADDON_BINARY.build.json" "$APP_MIDDLEWARE_METADATA/middleware-codex-oauth.build.json"
fi
if [ -x "$POCKETKERNEL_ADDON_BINARY" ]; then
  cp "$POCKETKERNEL_ADDON_BINARY" "$APP_HELPERS/pocketkernel"
  chmod 755 "$APP_HELPERS/pocketkernel"
  cp "$POCKETKERNEL_ADDON_BINARY.build.json" "$APP_POCKETKERNEL_METADATA/pocketkernel.build.json"
fi
cp "$ROOT_DIR/src/mcp/pocketwiki-mcp-server.mjs" "$APP_MCP/pocketwiki-mcp-server.mjs"
cp "$ROOT_DIR/src/mcp/pocketwiki-evidence-core.mjs" "$APP_MCP/pocketwiki-evidence-core.mjs"

BUILD_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
RESOURCE_BUNDLE="$BUILD_DIR/PocketWikiMac_PocketWikiMac.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  case "$MODE" in
    --bundle|bundle)
      ditto --noextattr --norsrc "$RESOURCE_BUNDLE" "$APP_BUNDLE/$(basename "$RESOURCE_BUNDLE")"
      ;;
    *)
      ditto --noextattr --norsrc "$RESOURCE_BUNDLE" "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
      ;;
  esac
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
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>PocketWikiReleaseTag</key>
  <string>$RELEASE_TAG</string>
  <key>PocketWikiCommitSHA</key>
  <string>$COMMIT_SHA</string>
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
</dict>
</plist>
PLIST

case "$MODE" in
  --bundle|bundle)
    ;;
  *)
    codesign_app_bundle "$APP_BUNDLE" "$BUNDLE_ID" "$SIGNING_IDENTITY"
    ;;
esac

open_app() {
  env -u POCKETWIKI_ENV_PATH /usr/bin/open -n "$APP_BUNDLE"
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
    clean_bundle_metadata "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
