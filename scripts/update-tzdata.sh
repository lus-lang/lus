#!/bin/sh
# Regenerate the embedded IANA tzdata blob (lus/src/ltzdata.c).
#
# By default this reads the already-compiled TZif files from the system tz
# database (/usr/share/zoneinfo), so no `zic` is required. To embed a specific
# upstream release instead, fetch and compile it first, then point this script
# at the resulting directory:
#
#   curl -LO https://data.iana.org/time-zones/releases/tzdata2026b.tar.gz
#   curl -LO https://data.iana.org/time-zones/releases/tzcode2026b.tar.gz
#   mkdir tzbuild && tar -C tzbuild -xf tzdata2026b.tar.gz \
#     && tar -C tzbuild -xf tzcode2026b.tar.gz
#   make -C tzbuild TOPDIR="$PWD/tzout" install
#   scripts/update-tzdata.sh "$PWD/tzout/usr/share/zoneinfo"
#
# tzdata is public domain, so the embedded bytes carry no licensing obligation.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZONEINFO="${1:-/usr/share/zoneinfo}"
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
