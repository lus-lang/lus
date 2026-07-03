#!/bin/sh
# Refresh the vendored SQLite amalgamation (lus/vendor/sqlite/).
#
# SQLite ships as a single-file amalgamation that liblus compiles directly,
# so updating means replacing two files. Bump the release constants below to
# the desired version from https://www.sqlite.org/download.html, then run
# this script from anywhere inside the repository.
#
# SQLite is public domain, so the vendored sources carry no licensing
# obligation. licenses/LICENSE.SQLITE.txt records the blessing.
set -eu

SQLITE_YEAR="2026"
SQLITE_RELEASE="3530300" # 3.53.3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/lus/vendor/sqlite"
URL="https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_RELEASE.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching $URL"
curl -sL -o "$TMP/sqlite.zip" "$URL"
unzip -o -q "$TMP/sqlite.zip" -d "$TMP"

mkdir -p "$OUT"
cp "$TMP/sqlite-amalgamation-$SQLITE_RELEASE/sqlite3.c" "$OUT/sqlite3.c"
cp "$TMP/sqlite-amalgamation-$SQLITE_RELEASE/sqlite3.h" "$OUT/sqlite3.h"

echo "updated $OUT to sqlite-amalgamation-$SQLITE_RELEASE"
