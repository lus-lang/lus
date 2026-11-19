#!/bin/sh
# Regenerate the embedded IANA tzdata blob (lus/src/ltzdata.c).
#
# With no argument this fetches the pinned IANA data and compiler sources,
# verifies both archives, and builds the release's TZif files. Pass an existing
# zoneinfo directory as the first argument for an offline regeneration.
#
# tzdata is public domain, so the embedded bytes carry no licensing obligation.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TZDATA_VERSION="2026c"
TZDATA_SHA256="e4a178a4477f3d0ea77cc31828ff72aa38feff8d61aa13e7e99e142e9d902be4"
TZCODE_SHA256="b1cffc3ace4c4c7cd0efba2f7add86ec3d0b79da48bcf03582671fd3c8feace8"
TMP=""

verify_sha256() {
  expected="$1"
  file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | sha256sum --check --strict -
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | shasum -a 256 --check -
  else
    echo "error: a SHA-256 verification tool is required" >&2
    exit 1
  fi
}

if [ "$#" -gt 0 ]; then
  ZONEINFO="$1"
else
  for tool in curl make tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "error: $tool is required to build tzdata" >&2
      exit 1
    fi
  done
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  base="https://data.iana.org/time-zones/releases"
  data="$TMP/tzdata$TZDATA_VERSION.tar.gz"
  code="$TMP/tzcode$TZDATA_VERSION.tar.gz"
  curl -fsSL "$base/tzdata$TZDATA_VERSION.tar.gz" -o "$data"
  curl -fsSL "$base/tzcode$TZDATA_VERSION.tar.gz" -o "$code"
  verify_sha256 "$TZDATA_SHA256" "$data"
  verify_sha256 "$TZCODE_SHA256" "$code"
  mkdir "$TMP/src"
  tar -C "$TMP/src" -xf "$data"
  tar -C "$TMP/src" -xf "$code"
  make -C "$TMP/src" TOPDIR="$TMP/out" install
  ZONEINFO="$TMP/out/usr/share/zoneinfo"
fi
OUT="${2:-$ROOT/lus/src/ltzdata.c}"

if [ ! -d "$ZONEINFO" ]; then
  echo "error: zoneinfo directory not found: $ZONEINFO" >&2
  exit 1
fi
if ! command -v zstd >/dev/null 2>&1; then
  echo "error: zstd CLI is required" >&2
  exit 1
fi

node "$ROOT/scripts/gen-tzdata.js" "$ZONEINFO" "$OUT"
