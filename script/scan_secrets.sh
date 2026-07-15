#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

fail() {
  printf '%s\n' "erro: $*" >&2
  exit 1
}

tracked_env="$(
  git -C "$ROOT_DIR" ls-files |
    grep -E '(^|/)\.env($|\.)' |
    grep -Ev '(^|/)\.env\.example$' || true
)"
[ -z "$tracked_env" ] || fail "arquivo .env versionado detectado: $tracked_env"

tracked_signing_files="$(
  git -C "$ROOT_DIR" ls-files |
    grep -Ei '\.(p8|p12|cer|pem|key|mobileprovision|provisionprofile|xcarchive)$' || true
)"
[ -z "$tracked_signing_files" ] || fail "material de signing versionado detectado: $tracked_signing_files"

leaks="$(
  git -C "$ROOT_DIR" grep -n -I -E \
    '(Apple Development: .*\([A-Z0-9]{10}\)|Developer ID Application: .*\([A-Z0-9]{10}\)|TeamIdentifier=[A-Z0-9]{10}|ASC_KEY_ID[[:space:]]*=[[:space:]]*[^[:space:]"]|ASC_ISSUER_ID[[:space:]]*=[[:space:]]*[^[:space:]"]|APP_STORE_CONNECT[^[:space:]]*[[:space:]]*=[[:space:]]*[^[:space:]"]|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
    -- . ':!docs' ':!Docs' ':!Tests' ':!*.md' ':!script/scan_secrets.sh' || true
)"
[ -z "$leaks" ] || fail "possível segredo de developer account no git:\n$leaks"

unignored_sensitive="$(
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f \( \
      -name '.env' -o \
      -name '.env.*' -o \
      -iname '*.p8' -o \
      -iname '*.p12' -o \
      -iname '*.cer' -o \
      -iname '*.pem' -o \
      -iname '*.key' -o \
      -iname '*.mobileprovision' -o \
      -iname '*.provisionprofile' \
    \) -print |
    while IFS= read -r path; do
      rel="${path#$ROOT_DIR/}"
      [ "$rel" = ".env.example" ] && continue
      if ! git -C "$ROOT_DIR" check-ignore -q -- "$rel"; then
        printf '%s\n' "$rel"
      fi
    done
)"
[ -z "$unignored_sensitive" ] || fail "arquivo sensível local não está coberto pelo .gitignore:\n$unignored_sensitive"

printf '%s\n' "scan de segredos OK"
