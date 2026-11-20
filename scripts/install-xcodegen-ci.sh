#!/bin/sh
set -eu

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

install_dir="$RUNNER_TEMP/xcodegen-2.46.0"
archive="$RUNNER_TEMP/xcodegen-2.46.0.zip"
curl -fsSL --retry 3 -o "$archive" https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
printf '%s  %s\n' '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' "$archive" | shasum -a 256 -c -
mkdir -p "$install_dir"
unzip -oq "$archive" -d "$install_dir"
test "$("$install_dir/xcodegen/bin/xcodegen" --version)" = 'Version: 2.46.0'
printf '%s\n' "$install_dir/xcodegen/bin" >> "$GITHUB_PATH"
