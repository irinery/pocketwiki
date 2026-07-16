#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
RESOLVER="$ROOT_DIR/script/resolve_release_version.sh"
TEST_REPO="$(mktemp -d "${TMPDIR:-/tmp}/pocketwiki-release-test.XXXXXX")"
trap 'rm -rf "$TEST_REPO"' EXIT INT TERM

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.name "PocketWiki Test"
git -C "$TEST_REPO" config user.email "pocketwiki@example.invalid"

commit() {
  message="$1"
  printf '%s\n' "$message" >>"$TEST_REPO/history.txt"
  git -C "$TEST_REPO" add history.txt
  git -C "$TEST_REPO" commit -q -m "$message"
}

resolve() {
  channel="$1"
  key="$2"
  POCKETWIKI_RELEASE_REPO="$TEST_REPO" \
    POCKETWIKI_RELEASE_BASE_VERSION="0.1.0" \
    POCKETWIKI_RELEASE_CHANNEL="$channel" \
    "$RESOLVER" --print "$key"
}

assert_equal() {
  expected="$1"
  actual="$2"
  [ "$expected" = "$actual" ] || {
    printf 'esperado: %s\nobtido: %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

commit "chore: initial"
assert_equal "alpha-0.1.0" "$(resolve alpha release_tag)"

MAIN_BRANCH="$(git -C "$TEST_REPO" branch --show-current)"
git -C "$TEST_REPO" switch -q -c unrelated-release
commit "feat: unrelated future"
git -C "$TEST_REPO" tag alpha-9.0.0
git -C "$TEST_REPO" switch -q "$MAIN_BRANCH"

git -C "$TEST_REPO" tag v0.1.0
git -C "$TEST_REPO" tag v99.0
assert_equal "v0.1.0" "$(resolve alpha previous_release_tag)"
assert_equal "alpha-0.1.0" "$(resolve alpha release_tag)"

commit "fix: updater retry"
assert_equal "alpha-0.1.1" "$(resolve alpha release_tag)"
assert_equal "patch" "$(resolve alpha release_bump)"

git -C "$TEST_REPO" tag alpha-0.1.1
commit "feat: canonical updater"
assert_equal "alpha-0.2.0" "$(resolve alpha release_tag)"
assert_equal "minor" "$(resolve alpha release_bump)"

git -C "$TEST_REPO" tag alpha-0.2.0
commit "feat!: replace update protocol"
assert_equal "alpha-1.0.0" "$(resolve alpha release_tag)"
assert_equal "major" "$(resolve alpha release_bump)"

git -C "$TEST_REPO" tag alpha-1.0.0
assert_equal "alpha-1.0.0" "$(resolve stable previous_release_tag)"
assert_equal "1.0.0" "$(resolve stable release_tag)"
assert_equal "none" "$(resolve stable release_bump)"

git -C "$TEST_REPO" tag 1.0.0
commit "docs: stable channel"
assert_equal "1.0.1" "$(resolve stable release_tag)"
assert_equal "patch" "$(resolve stable release_bump)"

printf '%s\n' "resolve_release_version: ok"
