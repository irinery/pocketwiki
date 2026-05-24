#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

npm --prefix "$ROOT_DIR" run build:excalidraw
swift build --package-path "$ROOT_DIR"
"$ROOT_DIR"/script/run_core_tests.sh
"$ROOT_DIR"/script/run_integration_tests.sh
