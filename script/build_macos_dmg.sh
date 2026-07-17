#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/script"
PRODUCT_NAME="PocketWikiMac"
APP_NAME="PocketWiki"
BUNDLE_ID="com.irinery.PocketWikiMac"
MIN_SYSTEM_VERSION="14.0"

# shellcheck source=script/signing.sh
. "$SCRIPT_DIR/signing.sh"
load_env_file "$ROOT_DIR/.env"
load_env_file "$ROOT_DIR/.env.local"
BUNDLE_ID="${POCKETWIKI_BUNDLE_ID:-$BUNDLE_ID}"

APP_VERSION="${APP_VERSION:-$("$SCRIPT_DIR/resolve_release_version.sh" --print app_version)}"
RELEASE_TAG="${RELEASE_TAG:-$("$SCRIPT_DIR/resolve_release_version.sh" --print release_tag)}"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf "unknown")}"

printf '%s\n' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  printf 'invalid app version: %s\n' "$APP_VERSION" >&2
  exit 2
}
case "$RELEASE_TAG" in
  *[!A-Za-z0-9._-]*) printf 'invalid release tag: %s\n' "$RELEASE_TAG" >&2; exit 2 ;;
esac

MACOS_ARCHS="${MACOS_ARCHS:-arm64 x86_64}"
if [ -n "${SIGN_IDENTITY:-}" ] && [ -z "${POCKETWIKI_SIGNING_IDENTITY:-}" ]; then
  POCKETWIKI_SIGNING_IDENTITY="$SIGN_IDENTITY"
fi
SIGN_MODE="${POCKETWIKI_SIGN_MODE:-auto}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf "1")}"

DIST_DIR="$ROOT_DIR/dist/release"
WORK_DIR="$ROOT_DIR/.build/macos-dmg"
STAGE_DIR="$WORK_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
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

HAS_ARM64=0
HAS_X86_64=0
for arch in $MACOS_ARCHS; do
  case "$arch" in
    arm64)
      HAS_ARM64=1
      ;;
    x86_64)
      HAS_X86_64=1
      ;;
  esac
done

if [ "$HAS_ARM64" -eq 1 ] && [ "$HAS_X86_64" -eq 1 ]; then
  ARCH_LABEL="universal"
elif [ "$HAS_ARM64" -eq 1 ]; then
  ARCH_LABEL="apple-silicon"
elif [ "$HAS_X86_64" -eq 1 ]; then
  ARCH_LABEL="intel"
else
  ARCH_LABEL="custom"
fi

ASSET_BASENAME="$APP_NAME-$RELEASE_TAG-macOS-$ARCH_LABEL"
DMG_NAME="$ASSET_BASENAME.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
ZIP_NAME="$ASSET_BASENAME.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
MANIFEST_NAME="$ASSET_BASENAME.build.json"
MANIFEST_PATH="$DIST_DIR/$MANIFEST_NAME"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

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

need_node_deps() {
  [ ! -x "$ROOT_DIR/node_modules/.bin/vite" ] || [ ! -f "$ROOT_DIR/node_modules/lz-string/libs/lz-string.min.js" ]
}

detach_mount() {
  mount_dir="$1"
  if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
    hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    rmdir "$mount_dir" 2>/dev/null || true
  fi
}

swift_arch_args() {
  for arch in $MACOS_ARCHS; do
    case "$arch" in
      arm64|x86_64)
        printf " --arch %s" "$arch"
        ;;
      *)
        printf "invalid architecture: %s\n" "$arch" >&2
        exit 2
        ;;
    esac
  done
}

echo "==> Preparing web bundles"
if need_node_deps; then
  npm --prefix "$ROOT_DIR" ci --include=dev
fi
npm --prefix "$ROOT_DIR" run build:excalidraw
npm --prefix "$ROOT_DIR" run build:graph-view

echo "==> Building $APP_NAME $APP_VERSION for:$MACOS_ARCHS"
# shellcheck disable=SC2046
swift build --package-path "$ROOT_DIR" -c release --product "$PRODUCT_NAME" $(swift_arch_args)
# shellcheck disable=SC2046
BUILD_PRODUCTS_DIR="$(swift build --package-path "$ROOT_DIR" -c release $(swift_arch_args) --show-bin-path)"
BUILD_BINARY="$BUILD_PRODUCTS_DIR/$PRODUCT_NAME"
RESOURCE_BUNDLE="$BUILD_PRODUCTS_DIR/PocketWikiMac_PocketWikiMac.bundle"

test -x "$BUILD_BINARY"
test -d "$RESOURCE_BUNDLE"

echo "==> Staging app bundle"
rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_WEB" "$APP_HELPERS" "$APP_MIDDLEWARE_METADATA" "$APP_POCKETKERNEL_METADATA" "$APP_MCP" "$DIST_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
ditto --noextattr --norsrc "$RESOURCE_BUNDLE" "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"

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
</dict>
</plist>
PLIST

for arch in $MACOS_ARCHS; do
  lipo -archs "$APP_BINARY" | tr " " "\n" | grep -qx "$arch"
done

echo "==> Signing app bundle"
codesign_app_bundle "$APP_BUNDLE" "$BUNDLE_ID" "$SIGNING_IDENTITY"

echo "==> Creating update archive"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$ZIP_NAME" >"$ZIP_NAME.sha256"
)

echo "==> Creating DMG"
RW_DMG="$WORK_DIR/$APP_NAME-rw.dmg"
BUILD_MOUNT_DIR="$(mktemp -d /tmp/pocketwiki-dmg-build.XXXXXX)"
VERIFY_MOUNT_DIR="$(mktemp -d /tmp/pocketwiki-dmg-verify.XXXXXX)"
trap 'detach_mount "$BUILD_MOUNT_DIR"; detach_mount "$VERIFY_MOUNT_DIR"' EXIT HUP INT TERM

APP_SIZE_KB="$(du -sk "$APP_BUNDLE" | awk '{ print $1 }')"
DMG_SIZE_MB=$((APP_SIZE_KB / 1024 + 64))
if [ "$DMG_SIZE_MB" -lt 128 ]; then
  DMG_SIZE_MB=128
fi

hdiutil create -volname "$APP_NAME" -size "${DMG_SIZE_MB}m" -fs HFS+ -ov "$RW_DMG" >/dev/null
hdiutil attach -nobrowse -readwrite -mountpoint "$BUILD_MOUNT_DIR" "$RW_DMG" >/dev/null
ditto --noextattr --noqtn "$APP_BUNDLE" "$BUILD_MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$BUILD_MOUNT_DIR/Applications"
xattr -cr "$BUILD_MOUNT_DIR/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$BUILD_MOUNT_DIR/$APP_NAME.app"
detach_mount "$BUILD_MOUNT_DIR"

hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH" -ov >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MOUNT_DIR" "$DMG_PATH" >/dev/null
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT_DIR/$APP_NAME.app"
detach_mount "$VERIFY_MOUNT_DIR"
trap - EXIT HUP INT TERM

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256"
)

node - "$MANIFEST_PATH" "$RELEASE_TAG" "$APP_VERSION" "$BUILD_NUMBER" "$COMMIT_SHA" "$BUNDLE_ID" "$ZIP_NAME" "$DMG_NAME" "$APP_BUNDLE/Contents/Resources/Addons/MiddlewareAuth/middleware-codex-oauth.build.json" "$APP_BUNDLE/Contents/Resources/Addons/PocketKernel/pocketkernel.build.json" <<'NODE'
const fs = require("node:fs");
const [path, releaseTag, appVersion, buildNumber, commit, bundleID, zip, dmg, middlewareManifestPath, kernelManifestPath] = process.argv.slice(2);
const manifest = {
  schema_version: "pocketwiki.build.v1",
  release_tag: releaseTag,
  app_version: appVersion,
  build_number: buildNumber,
  commit,
  bundle_id: bundleID,
  assets: { zip, dmg },
};
manifest.addons = {};
if (fs.existsSync(middlewareManifestPath)) {
  manifest.addons.middleware_auth = JSON.parse(fs.readFileSync(middlewareManifestPath, "utf8"));
}
if (fs.existsSync(kernelManifestPath)) {
  manifest.addons.pocket_kernel = JSON.parse(fs.readFileSync(kernelManifestPath, "utf8"));
}
if (Object.keys(manifest.addons).length === 0) {
  delete manifest.addons;
}
fs.writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

echo "==> Created $DMG_PATH"
echo "==> Created $ZIP_PATH"
echo "==> Created $MANIFEST_PATH"
echo "==> SHA256 $(cat "$DMG_PATH.sha256")"
