#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MIDDLEWARE_AUTH_MODULE="github.com/irinery/middlewareAuth"
MIDDLEWARE_AUTH_REF="${MIDDLEWARE_AUTH_REF:-196ba5f40ec69c2be2d283b503c1dd6fa5c40b4f}"
MACOS_ARCHS="${MACOS_ARCHS:-arm64 x86_64}"
OUTPUT="${1:-$ROOT_DIR/.build/middleware-auth-addon/middleware-codex-oauth}"
WORK_DIR="$ROOT_DIR/.build/middleware-auth-addon/work"
MANIFEST="$OUTPUT.build.json"

case "$MIDDLEWARE_AUTH_REF" in
  *[!A-Za-z0-9._/-]*)
    printf 'invalid MiddlewareAuth ref: %s\n' "$MIDDLEWARE_AUTH_REF" >&2
    exit 2
    ;;
esac

rm -rf "$WORK_DIR"
rm -f "$OUTPUT" "$MANIFEST"
mkdir -p "$WORK_DIR" "$(dirname "$OUTPUT")"

if [ -n "${POCKETWIKI_MIDDLEWARE_AUTH_BINARY:-}" ]; then
  test -x "$POCKETWIKI_MIDDLEWARE_AUTH_BINARY" || {
    printf 'MiddlewareAuth binary is not executable: %s\n' "$POCKETWIKI_MIDDLEWARE_AUTH_BINARY" >&2
    exit 2
  }
  cp "$POCKETWIKI_MIDDLEWARE_AUTH_BINARY" "$OUTPUT"
else
  command -v go >/dev/null 2>&1 || {
    printf 'Go is required to build the MiddlewareAuth add-on\n' >&2
    exit 69
  }
  if [ -n "${MIDDLEWARE_AUTH_SOURCE_DIR:-}" ]; then
    test -f "$MIDDLEWARE_AUTH_SOURCE_DIR/go.mod" || {
      printf 'MiddlewareAuth source is invalid: %s\n' "$MIDDLEWARE_AUTH_SOURCE_DIR" >&2
      exit 2
    }
    source_ref="$(git -C "$MIDDLEWARE_AUTH_SOURCE_DIR" rev-parse "$MIDDLEWARE_AUTH_REF^{commit}")"
    test "$source_ref" = "$MIDDLEWARE_AUTH_REF" || {
      printf 'MiddlewareAuth source does not contain the exact ref: expected %s, got %s\n' "$MIDDLEWARE_AUTH_REF" "$source_ref" >&2
      exit 2
    }
    SOURCE_BUILD_DIR="$WORK_DIR/source"
    mkdir -p "$SOURCE_BUILD_DIR"
    git -C "$MIDDLEWARE_AUTH_SOURCE_DIR" archive "$MIDDLEWARE_AUTH_REF" | tar -x -C "$SOURCE_BUILD_DIR"
  fi
  GO_MODULE_CACHE="$(go env GOMODCACHE)"

  built=""
  for arch in $MACOS_ARCHS; do
    case "$arch" in
      arm64) go_arch="arm64" ;;
      x86_64) go_arch="amd64" ;;
      *) printf 'invalid MiddlewareAuth architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac

    arch_dir="$WORK_DIR/$arch"
    mkdir -p "$arch_dir"
    printf '==> Building MiddlewareAuth %s for darwin/%s\n' "$MIDDLEWARE_AUTH_REF" "$arch"
    arch_binary="$arch_dir/middleware-codex-oauth"
    if [ -n "${MIDDLEWARE_AUTH_SOURCE_DIR:-}" ]; then
      (
        cd "$SOURCE_BUILD_DIR"
        GOMODCACHE="$GO_MODULE_CACHE" GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 \
          go build -trimpath -o "$arch_binary" ./cmd/middleware-codex-oauth
      )
    else
      GOPATH="$arch_dir/gopath" GOMODCACHE="$GO_MODULE_CACHE" GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 \
        go install "$MIDDLEWARE_AUTH_MODULE/cmd/middleware-codex-oauth@$MIDDLEWARE_AUTH_REF"
      installed="$(find "$arch_dir/gopath/bin" -type f -name middleware-codex-oauth -print | head -n 1)"
      test -n "$installed"
      cp "$installed" "$arch_binary"
    fi
    test -n "$arch_binary"
    test -x "$arch_binary"
    built="$built $arch_binary"
  done

  # shellcheck disable=SC2086
  if [ "$(printf '%s\n' $built | wc -l | tr -d ' ')" -gt 1 ]; then
    # shellcheck disable=SC2086
    lipo -create $built -output "$OUTPUT"
  else
    # shellcheck disable=SC2086
    cp $built "$OUTPUT"
  fi
fi

chmod 755 "$OUTPUT"
SHA256="$(shasum -a 256 "$OUTPUT" | awk '{ print $1 }')"
ARCHES="$(lipo -archs "$OUTPUT" 2>/dev/null || file "$OUTPUT")"

cat >"$MANIFEST" <<JSON
{
  "schema_version": "pocketwiki.middleware-auth-addon.v1",
  "module": "$MIDDLEWARE_AUTH_MODULE",
  "ref": "$MIDDLEWARE_AUTH_REF",
  "architectures": "$ARCHES",
  "sha256": "$SHA256"
}
JSON

rm -rf "$WORK_DIR"
printf '==> MiddlewareAuth add-on: %s\n' "$OUTPUT"
