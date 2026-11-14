#!/bin/sh
set -eu
bundle=${1:?bundle path required}
for root in "$bundle" "$bundle/Contents/Resources"; do
  if [ -f "$root/wiki-review.md" ] &&
     [ -f "$root/ExcalidrawEditor/index.html" ] &&
     [ -f "$root/ExcalidrawEditor/THIRD_PARTY_NOTICES.md" ]; then
    exit 0
  fi
done
printf '%s\n' "required resources missing from bundle: $bundle" >&2
exit 1
