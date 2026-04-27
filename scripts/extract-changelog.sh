#!/usr/bin/env bash
# Print the CHANGELOG.md section for a given version as raw markdown.
# Used by the release workflow to populate GitHub Release notes and the
# Sparkle appcast description. Exits 0 with empty output if the version
# isn't found, so callers can decide on a fallback.
#
# Usage: scripts/extract-changelog.sh <version>
#   e.g. scripts/extract-changelog.sh 1.0.0
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
CHANGELOG="${CHANGELOG_PATH:-CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
  echo "Error: $CHANGELOG not found" >&2
  exit 1
fi

awk -v ver="$VERSION" '
  $1 == "##" {
    if (in_section) exit
    v = $2
    gsub(/[\[\]]/, "", v)
    if (v == ver) { in_section = 1; next }
  }
  in_section {
    if (/^$/) { ws = ws "\n"; next }
    printf "%s%s\n", ws, $0
    ws = ""
  }
' "$CHANGELOG"
