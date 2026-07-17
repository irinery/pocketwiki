#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCHEMA_DIR="$ROOT_DIR/docs/rfcs/schemas"
EXAMPLE_DIR="$ROOT_DIR/docs/rfcs/examples"

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'erro: jq é obrigatório para validar os contratos Pocket' >&2
  exit 1
}
command -v npx >/dev/null 2>&1 || {
  printf '%s\n' 'erro: npx é obrigatório para executar o validador JSON Schema' >&2
  exit 1
}

for file in "$SCHEMA_DIR"/*.json "$EXAMPLE_DIR"/*.json; do
  jq empty "$file"
done

npx --yes ajv-cli@5.0.0 validate --spec=draft2020 \
  -s "$SCHEMA_DIR/pocket-app-manifest.v1.schema.json" \
  -d "$EXAMPLE_DIR/*.managed-addon.json" \
  -d "$EXAMPLE_DIR/*.external-local.json" \
  -d "$EXAMPLE_DIR/*.external-remote.json"

npx --yes ajv-cli@5.0.0 validate --spec=draft2020 \
  -s "$SCHEMA_DIR/pocket-app-instance.v1.schema.json" \
  -d "$EXAMPLE_DIR/pockettrace.instance.json"

npx --yes ajv-cli@5.0.0 validate --spec=draft2020 \
  -s "$SCHEMA_DIR/pocket-event.v1.schema.json" \
  -d "$EXAMPLE_DIR/addon-failure.event.json"

printf '%s\n' 'Pocket Interop Contract válido'
