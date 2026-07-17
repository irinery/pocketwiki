#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
POCKETKERNEL_MODULE="github.com/irinery/pocketkernel"
POCKETKERNEL_REF="${POCKETKERNEL_REF:-b0453b87ba06575bb5a8187b71e5baa07a843c36}"
MACOS_ARCHS="${MACOS_ARCHS:-arm64 x86_64}"
OUTPUT="${1:-$ROOT_DIR/.build/pocketkernel-addon/pocketkernel}"
WORK_DIR="$ROOT_DIR/.build/pocketkernel-addon/work"
MANIFEST="$OUTPUT.build.json"

case "$POCKETKERNEL_REF" in
  *[!A-Za-z0-9._/-]*)
    printf 'invalid PocketKernel ref: %s\n' "$POCKETKERNEL_REF" >&2
    exit 2
    ;;
esac

rm -rf "$WORK_DIR"
rm -f "$OUTPUT" "$MANIFEST"
mkdir -p "$WORK_DIR" "$(dirname "$OUTPUT")"

if [ -n "${POCKETWIKI_POCKETKERNEL_BINARY:-}" ]; then
  test -x "$POCKETWIKI_POCKETKERNEL_BINARY" || {
    printf 'PocketKernel binary is not executable: %s\n' "$POCKETWIKI_POCKETKERNEL_BINARY" >&2
    exit 2
  }
  cp "$POCKETWIKI_POCKETKERNEL_BINARY" "$OUTPUT"
else
  command -v go >/dev/null 2>&1 || {
    printf 'Go is required to build the PocketKernel add-on\n' >&2
    exit 69
  }
  if [ -n "${POCKETKERNEL_SOURCE_DIR:-}" ]; then
    test -f "$POCKETKERNEL_SOURCE_DIR/go.mod" || {
      printf 'PocketKernel source is invalid: %s\n' "$POCKETKERNEL_SOURCE_DIR" >&2
      exit 2
    }
    source_ref="$(git -C "$POCKETKERNEL_SOURCE_DIR" rev-parse "$POCKETKERNEL_REF^{commit}")"
    test "$source_ref" = "$POCKETKERNEL_REF" || {
      printf 'PocketKernel source does not contain the exact ref: expected %s, got %s\n' "$POCKETKERNEL_REF" "$source_ref" >&2
      exit 2
    }
    SOURCE_BUILD_DIR="$WORK_DIR/source"
    mkdir -p "$SOURCE_BUILD_DIR"
    git -C "$POCKETKERNEL_SOURCE_DIR" archive "$POCKETKERNEL_REF" | tar -x -C "$SOURCE_BUILD_DIR"
  fi

  GO_MODULE_CACHE="$(go env GOMODCACHE)"
  built=""
  for arch in $MACOS_ARCHS; do
    case "$arch" in
      arm64) go_arch="arm64" ;;
      x86_64) go_arch="amd64" ;;
      *) printf 'invalid PocketKernel architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac

    arch_dir="$WORK_DIR/$arch"
    arch_binary="$arch_dir/pocketkernel"
    mkdir -p "$arch_dir"
    printf '==> Building PocketKernel %s for darwin/%s\n' "$POCKETKERNEL_REF" "$arch"
    if [ -n "${POCKETKERNEL_SOURCE_DIR:-}" ]; then
      (
        cd "$SOURCE_BUILD_DIR"
        GOMODCACHE="$GO_MODULE_CACHE" GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 \
          go build -trimpath -o "$arch_binary" ./cmd/pocketkernel
      )
    else
      GOPATH="$arch_dir/gopath" GOMODCACHE="$GO_MODULE_CACHE" GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 \
        go install "$POCKETKERNEL_MODULE/cmd/pocketkernel@$POCKETKERNEL_REF"
      installed="$(find "$arch_dir/gopath/bin" -type f -name pocketkernel -print | head -n 1)"
      test -n "$installed"
      cp "$installed" "$arch_binary"
    fi
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
  "schema_version": "pocketwiki.pocketkernel-addon.v1",
  "module": "$POCKETKERNEL_MODULE",
  "ref": "$POCKETKERNEL_REF",
  "architectures": "$ARCHES",
  "sha256": "$SHA256"
}
JSON

rm -rf "$WORK_DIR"
printf '==> PocketKernel add-on: %s\n' "$OUTPUT"
