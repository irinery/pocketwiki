#!/bin/sh
set -eu

NH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KERNEL_ROOT=${POCKETKERNEL_NH00_ROOT:-"$NH_ROOT/../pocketkernel-nh00"}
NH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nh00-kernel-build.XXXXXX")
trap 'rm -rf "$NH_TMP"' EXIT HUP INT TERM

(cd "$KERNEL_ROOT" && CGO_ENABLED=0 go build -trimpath -o "$NH_TMP/nh00-auth-probe" ./cmd/nh00-auth-probe)
node "$NH_ROOT/scripts/test-nh00-bootstrap-integration.mjs" "$NH_TMP/nh00-auth-probe"
