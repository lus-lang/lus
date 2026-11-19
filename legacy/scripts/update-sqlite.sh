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
SQLITE_RELEASE="3530400" # 3.53.4
SQLITE_SHA256="1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d"
SQLITE_C_SHA256="9197bba4d4801d12edbf33be1bc697f134aa291c43c9513e44a25ca05db03e2c"
SQLITE_H_SHA256="a398d9a0b477bfe89ad7c0e6657cddd961cace0b74e23189b3eab3a29bd792ce"
SQLITE_PATCH_SHA256="8773c8de30ceb37b0cf414d53fd0b1e2deb64a5ec7e27ae8943be8318a4e4c46"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/lus/vendor/sqlite"
PATCH="$ROOT/scripts/sqlite-lus-vfs.patch"
URL="https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_RELEASE.zip"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching $URL"
curl -fsSL -o "$TMP/sqlite.zip" "$URL"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$SQLITE_SHA256" "$TMP/sqlite.zip" |
    sha256sum --check --strict -
  printf '%s  %s\n' "$SQLITE_PATCH_SHA256" "$PATCH" |
    sha256sum --check --strict -
elif command -v shasum >/dev/null 2>&1; then
  printf '%s  %s\n' "$SQLITE_SHA256" "$TMP/sqlite.zip" |
    shasum -a 256 --check -
  printf '%s  %s\n' "$SQLITE_PATCH_SHA256" "$PATCH" |
    shasum -a 256 --check -
else
  echo "a SHA-256 verification tool is required" >&2
  exit 1
fi
unzip -o -q "$TMP/sqlite.zip" -d "$TMP"

STAGED="$TMP/staged"
mkdir -p "$STAGED"
cp "$TMP/sqlite-amalgamation-$SQLITE_RELEASE/sqlite3.c" "$STAGED/sqlite3.c"
cp "$TMP/sqlite-amalgamation-$SQLITE_RELEASE/sqlite3.h" "$STAGED/sqlite3.h"

if ! command -v patch >/dev/null 2>&1; then
  echo "patch is required to apply the Lus SQLite VFS integration" >&2
  exit 1
fi
patch -d "$STAGED" -p1 -f < "$PATCH"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$SQLITE_C_SHA256" "$STAGED/sqlite3.c" |
    sha256sum --check --strict -
  printf '%s  %s\n' "$SQLITE_H_SHA256" "$STAGED/sqlite3.h" |
    sha256sum --check --strict -
elif command -v shasum >/dev/null 2>&1; then
  printf '%s  %s\n' "$SQLITE_C_SHA256" "$STAGED/sqlite3.c" |
    shasum -a 256 --check -
  printf '%s  %s\n' "$SQLITE_H_SHA256" "$STAGED/sqlite3.h" |
    shasum -a 256 --check -
else
  echo "a SHA-256 verification tool is required" >&2
  exit 1
fi

mkdir -p "$OUT"
cp "$STAGED/sqlite3.c" "$OUT/sqlite3.c"
cp "$STAGED/sqlite3.h" "$OUT/sqlite3.h"

echo "updated $OUT to sqlite-amalgamation-$SQLITE_RELEASE with the Lus VFS patch"
