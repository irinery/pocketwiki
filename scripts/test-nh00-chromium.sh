#!/bin/sh
set -eu

NH_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nh00-playwright.XXXXXX")
trap 'rm -rf "$NH_TMP"' EXIT HUP INT TERM
export PLAYWRIGHT_BROWSERS_PATH="$NH_TMP/browsers"

cd "$NH_ROOT"
npx playwright install chromium
node scripts/smoke-nh00-chromium.mjs
