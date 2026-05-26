#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ ! -x "$ROOT_DIR/node_modules/.bin/vite" ] || [ ! -f "$ROOT_DIR/node_modules/lz-string/libs/lz-string.min.js" ]; then
  npm --prefix "$ROOT_DIR" ci --include=dev
fi

npm --prefix "$ROOT_DIR" run build:excalidraw
npm --prefix "$ROOT_DIR" run build:graph-view
npm --prefix "$ROOT_DIR" run test:graph-view
swift build --package-path "$ROOT_DIR"
"$ROOT_DIR"/script/run_core_tests.sh
"$ROOT_DIR"/script/run_integration_tests.sh
