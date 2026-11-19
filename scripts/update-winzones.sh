#!/bin/sh
# Regenerate the CLDR Windows-to-IANA mapping from a pinned CLDR release.
# CLDR data is under the Unicode license, which permits redistribution.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLDR_VERSION="48.2.1"
CLDR_COMMIT="26a79cb42bfcc90def764102aa2af126d9ef3108"
CLDR_SHA256="fa1ee8731ff106b66c003b55af19313a2498bd34ab4ae6261fb937c0b34f21d1"
URL="https://raw.githubusercontent.com/unicode-org/cldr-json/$CLDR_COMMIT/cldr-json/cldr-core/supplemental/windowsZones.json"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --max-time 60 "$URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMP" "$URL"
else
  echo "error: need curl or wget to fetch $URL" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$CLDR_SHA256" "$TMP" | sha256sum --check --strict -
elif command -v shasum >/dev/null 2>&1; then
  printf '%s  %s\n' "$CLDR_SHA256" "$TMP" | shasum -a 256 --check -
else
  echo "error: a SHA-256 verification tool is required" >&2
  exit 1
fi

node "$ROOT/scripts/gen-winzones.js" "$TMP" \
  "$ROOT/lus/src/lwinzones.c" "$CLDR_VERSION"
