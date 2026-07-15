#!/bin/sh

load_env_file() {
  file="$1"
  if [ -f "$file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a
  fi
}

select_signing_identity() {
  label="$1"
  security find-identity -v -p codesigning 2>/dev/null |
    awk -v label="$label" 'index($0, label) { print $2; exit }'
}

resolve_signing_identity() {
  mode="$1"
  configured="${POCKETWIKI_SIGNING_IDENTITY:-}"

  case "$mode" in
    adhoc|-)
      printf '%s' "-"
      return 0
      ;;
    auto)
      if [ -n "$configured" ]; then
        printf '%s' "$configured"
        return 0
      fi
      identity="$(select_signing_identity 'Apple Development:')"
      if [ -z "$identity" ]; then
        identity="$(select_signing_identity 'Developer ID Application:')"
      fi
      [ -n "$identity" ] || return 1
      printf '%s' "$identity"
      ;;
    *)
      printf '%s' "$mode"
      ;;
  esac
}

signing_label() {
  identity="$1"
  if [ "$identity" = "-" ]; then
    printf '%s' "ad-hoc"
  else
    printf '%s' "Apple identity (redacted)"
  fi
}

clean_bundle_metadata() {
  bundle="$1"

  find "$bundle" \( -name '.DS_Store' -o -name '._*' \) -delete
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$bundle" 2>/dev/null || true
    find "$bundle" -exec xattr -c {} + 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
    xattr -d com.apple.ResourceFork "$bundle" 2>/dev/null || true
    find "$bundle" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
    find "$bundle" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
  fi
}

require_signing_identity() {
  mode="$1"
  identity="$(resolve_signing_identity "$mode" || true)"
  if [ -z "$identity" ]; then
    cat >&2 <<'ERROR'
erro: nenhuma identidade de assinatura foi encontrada.
Use uma destas opções:
  1) configure POCKETWIKI_SIGNING_IDENTITY em .env.local com o hash do certificado;
  2) rode com POCKETWIKI_SIGN_MODE=adhoc para build sem conta Apple.
ERROR
    exit 70
  fi
  printf '%s' "$identity"
}

codesign_app_bundle() {
  bundle="$1"
  bundle_id="$2"
  identity="$3"

  printf '%s\n' "Assinando bundle: $(signing_label "$identity")"
  clean_bundle_metadata "$bundle"
  codesign \
    --force \
    --deep \
    --sign "$identity" \
    --timestamp=none \
    --identifier "$bundle_id" \
    "$bundle" >/dev/null
  clean_bundle_metadata "$bundle"
  codesign --verify --deep --strict "$bundle"
}
