#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_DIR="${POCKETWIKI_RELEASE_REPO:-$ROOT_DIR}"
CHANNEL="${POCKETWIKI_RELEASE_CHANNEL:-alpha}"
BASE_VERSION="${POCKETWIKI_RELEASE_BASE_VERSION:-}"
GITHUB_ENV_PATH=""
GITHUB_OUTPUT_PATH=""
PRINT_KEY=""

fail() {
  printf '%s\n' "erro: $*" >&2
  exit 64
}

usage() {
  printf '%s\n' "uso: $0 [--print chave] [--github-env arquivo] [--github-output arquivo]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print)
      [ "$#" -ge 2 ] || fail "--print exige uma chave"
      PRINT_KEY="$2"
      shift 2
      ;;
    --github-env)
      [ "$#" -ge 2 ] || fail "--github-env exige um arquivo"
      GITHUB_ENV_PATH="$2"
      shift 2
      ;;
    --github-output)
      [ "$#" -ge 2 ] || fail "--github-output exige um arquivo"
      GITHUB_OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      fail "argumento desconhecido: $1"
      ;;
  esac
done

case "$CHANNEL" in
  alpha|stable) ;;
  *) fail "POCKETWIKI_RELEASE_CHANNEL deve ser alpha ou stable" ;;
esac

if [ -z "$BASE_VERSION" ]; then
  BASE_VERSION="$({
    sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
      "$ROOT_DIR/package.json" | head -n 1
  } || true)"
fi
[ -n "$BASE_VERSION" ] || BASE_VERSION="0.1.0"

validate_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

validate_version "$BASE_VERSION" || fail "versao base invalida: $BASE_VERSION"
git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "diretorio nao e um repositorio Git: $REPO_DIR"

latest_git_release() {
  git -C "$REPO_DIR" tag --merged HEAD --list |
    sed -n \
      -e 's/^v\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2 \3 1 & legacy/p' \
      -e 's/^alpha-\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2 \3 2 & alpha/p' \
      -e 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1 \2 \3 3 & stable/p' |
    sort -k1,1n -k2,2n -k3,3n -k4,4n |
    awk 'NF { value = $5 "|" $1 "." $2 "." $3 "|" $6 } END { if (value != "") print value }'
}

version_part() {
  part="$1"
  version="$2"
  major="${version%%.*}"
  remainder="${version#*.}"
  minor="${remainder%%.*}"
  patch="${remainder#*.}"
  case "$part" in
    major) printf '%s\n' "$major" ;;
    minor) printf '%s\n' "$minor" ;;
    patch) printf '%s\n' "$patch" ;;
  esac
}

BASELINE="$(latest_git_release)"
PREVIOUS_RELEASE_TAG=""
RELEASE_BUMP="initial"
RELEASE_BUMP_REASON="nenhuma tag SemVer encontrada; usando versao base $BASE_VERSION"

if [ -n "$BASELINE" ]; then
  PREVIOUS_RELEASE_TAG="${BASELINE%%|*}"
  BASELINE_REST="${BASELINE#*|}"
  CURRENT_VERSION="${BASELINE_REST%%|*}"
  BASELINE_KIND="${BASELINE_REST#*|}"
  RANGE="$PREVIOUS_RELEASE_TAG..HEAD"
  COMMITS_SINCE="$(git -C "$REPO_DIR" rev-list --count "$RANGE")"

  if [ "$COMMITS_SINCE" -eq 0 ]; then
    RELEASE_BUMP="none"
    case "$CHANNEL:$BASELINE_KIND" in
      alpha:stable)
        fail "a tag estavel $PREVIOUS_RELEASE_TAG ja aponta para HEAD; o canal alpha nao pode regredir"
        ;;
      stable:alpha)
        RELEASE_BUMP_REASON="promovendo $PREVIOUS_RELEASE_TAG para a release estavel $CURRENT_VERSION"
        ;;
      alpha:legacy)
        RELEASE_BUMP_REASON="migrando a tag legada $PREVIOUS_RELEASE_TAG para alpha-$CURRENT_VERSION"
        ;;
      stable:legacy)
        RELEASE_BUMP_REASON="migrando a tag legada $PREVIOUS_RELEASE_TAG para $CURRENT_VERSION"
        ;;
      *)
        RELEASE_BUMP_REASON="tag $PREVIOUS_RELEASE_TAG ja aponta para este commit"
        ;;
    esac
  else
    LOG_TEXT="$(git -C "$REPO_DIR" log --format='%s%n%b' "$RANGE")"
    if printf '%s\n' "$LOG_TEXT" | grep -Eiq 'BREAKING[ -]CHANGE|^[[:space:]]*[[:alnum:]_-]+(\([^)]+\))?!:|(^|[^[:alnum:]])\[major\]([^[:alnum:]]|$)'; then
      RELEASE_BUMP="major"
      RELEASE_BUMP_REASON="breaking change detectado desde $PREVIOUS_RELEASE_TAG"
    elif printf '%s\n' "$LOG_TEXT" | grep -Eiq '^[[:space:]]*(feat|feature)(\([^)]+\))?:|(^|[^[:alnum:]])\[minor\]([^[:alnum:]]|$)'; then
      RELEASE_BUMP="minor"
      RELEASE_BUMP_REASON="feature detectada desde $PREVIOUS_RELEASE_TAG"
    else
      RELEASE_BUMP="patch"
      RELEASE_BUMP_REASON="correcao ou manutencao detectada desde $PREVIOUS_RELEASE_TAG"
    fi
  fi
else
  CURRENT_VERSION="$BASE_VERSION"
fi

MAJOR="$(version_part major "$CURRENT_VERSION")"
MINOR="$(version_part minor "$CURRENT_VERSION")"
PATCH="$(version_part patch "$CURRENT_VERSION")"

case "$RELEASE_BUMP" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  initial|none) ;;
  *) fail "incremento interno invalido: $RELEASE_BUMP" ;;
esac

APP_VERSION="$MAJOR.$MINOR.$PATCH"
if [ "$CHANNEL" = "alpha" ]; then
  RELEASE_TAG="alpha-$APP_VERSION"
  IS_PRERELEASE="true"
else
  RELEASE_TAG="$APP_VERSION"
  IS_PRERELEASE="false"
fi

write_values() {
  destination="$1"
  kind="$2"
  if [ "$kind" = "env" ]; then
    prefix="POCKETWIKI_"
  else
    prefix=""
  fi
  {
    printf '%sRELEASE_CHANNEL=%s\n' "$prefix" "$CHANNEL"
    printf '%sPREVIOUS_RELEASE_TAG=%s\n' "$prefix" "$PREVIOUS_RELEASE_TAG"
    printf '%sAPP_VERSION=%s\n' "$prefix" "$APP_VERSION"
    printf '%sRELEASE_TAG=%s\n' "$prefix" "$RELEASE_TAG"
    printf '%sRELEASE_BUMP=%s\n' "$prefix" "$RELEASE_BUMP"
    printf '%sRELEASE_BUMP_REASON=%s\n' "$prefix" "$RELEASE_BUMP_REASON"
    printf '%sIS_PRERELEASE=%s\n' "$prefix" "$IS_PRERELEASE"
  } >>"$destination"
}

[ -z "$GITHUB_ENV_PATH" ] || write_values "$GITHUB_ENV_PATH" env
[ -z "$GITHUB_OUTPUT_PATH" ] || write_values "$GITHUB_OUTPUT_PATH" output

case "$PRINT_KEY" in
  "")
    printf 'POCKETWIKI_RELEASE_CHANNEL=%s\n' "$CHANNEL"
    printf 'POCKETWIKI_PREVIOUS_RELEASE_TAG=%s\n' "$PREVIOUS_RELEASE_TAG"
    printf 'POCKETWIKI_APP_VERSION=%s\n' "$APP_VERSION"
    printf 'POCKETWIKI_RELEASE_TAG=%s\n' "$RELEASE_TAG"
    printf 'POCKETWIKI_RELEASE_BUMP=%s\n' "$RELEASE_BUMP"
    printf 'POCKETWIKI_RELEASE_BUMP_REASON=%s\n' "$RELEASE_BUMP_REASON"
    printf 'POCKETWIKI_IS_PRERELEASE=%s\n' "$IS_PRERELEASE"
    ;;
  release_channel) printf '%s\n' "$CHANNEL" ;;
  previous_release_tag) printf '%s\n' "$PREVIOUS_RELEASE_TAG" ;;
  app_version) printf '%s\n' "$APP_VERSION" ;;
  release_tag) printf '%s\n' "$RELEASE_TAG" ;;
  release_bump) printf '%s\n' "$RELEASE_BUMP" ;;
  release_bump_reason) printf '%s\n' "$RELEASE_BUMP_REASON" ;;
  is_prerelease) printf '%s\n' "$IS_PRERELEASE" ;;
  *) fail "chave desconhecida: $PRINT_KEY" ;;
esac
