#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec node "$ROOT/Tests/NewHarnessE2E/gate-aggregator.mjs" "$@"
