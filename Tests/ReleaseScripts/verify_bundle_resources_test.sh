#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pocketwiki-bundle-layout.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
verify="$ROOT/script/verify_bundle_resources.sh"
for layout in flat structured; do
  bundle="$TMP/$layout"
  resources="$bundle"
  [ "$layout" = flat ] || resources="$bundle/Contents/Resources"
  mkdir -p "$resources/ExcalidrawEditor"
  : > "$resources/wiki-review.md"
  : > "$resources/ExcalidrawEditor/index.html"
  : > "$resources/ExcalidrawEditor/THIRD_PARTY_NOTICES.md"
  sh "$verify" "$bundle"
  rm "$resources/ExcalidrawEditor/index.html"
  if sh "$verify" "$bundle" >/dev/null 2>&1; then
    printf '%s\n' "missing resource accepted: $layout" >&2
    exit 1
  fi
done
printf '%s\n' 'ok - SwiftPM bundle layouts'
