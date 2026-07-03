#!/bin/sh
# Regenerate the CLDR Windows-to-IANA mapping (lus/src/lwinzones.c) from upstream
# CLDR. CLDR data is under the Unicode license, which permits redistribution.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://raw.githubusercontent.com/unicode-org/cldr/main/common/supplemental/windowsZones.xml"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -sSL --max-time 60 "$URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMP" "$URL"
else
  echo "error: need curl or wget to fetch $URL" >&2
  exit 1
fi

node "$ROOT/scripts/gen-winzones.js" "$TMP" "$ROOT/lus/src/lwinzones.c"
