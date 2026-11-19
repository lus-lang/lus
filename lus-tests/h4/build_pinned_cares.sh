#!/bin/sh
# Build the release-pinned c-ares source for both sides of H4 qualification.

set -eu

valid_sha256() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
}

verify_sha256() {
  expected=$1
  file=$2

  if ! valid_sha256 "$expected"; then
    echo "error: the stored SHA-256 digest is malformed" >&2
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    hash_tool=sha256sum
    hash_mode=sum
  elif command -v shasum >/dev/null 2>&1; then
    hash_tool=shasum
    hash_mode=shasum
  else
    echo "error: a SHA-256 verification tool is required" >&2
    return 1
  fi

  hash_output=$(mktemp "${TMPDIR:-/tmp}/lus-sha256.XXXXXX") || {
    echo "error: cannot create a SHA-256 verification file" >&2
    return 1
  }
  if [ "$hash_mode" = sum ]; then
    "$hash_tool" "$file" >"$hash_output" || hash_status=$?
  else
    "$hash_tool" -a 256 "$file" >"$hash_output" || hash_status=$?
  fi
  if [ "${hash_status:-0}" -ne 0 ]; then
    rm -f "$hash_output"
    echo "error: the SHA-256 tool failed" >&2
    return 1
  fi
  unset hash_status

  line_count=$(wc -l <"$hash_output")
  if [ "$line_count" -ne 1 ] || ! IFS= read -r hash_line <"$hash_output"; then
    rm -f "$hash_output"
    echo "error: the SHA-256 tool emitted ambiguous output" >&2
    return 1
  fi
  rm -f "$hash_output"

  actual=${hash_line%% *}
  if ! valid_sha256 "$actual" || [ "$hash_line" != "$actual  $file" ]; then
    echo "error: the SHA-256 tool emitted malformed output" >&2
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "error: c-ares source SHA-256 mismatch" >&2
    return 1
  fi
  printf '%s: OK\n' "$file" >&2
}

if [ "${1:-}" = "--verify-sha256" ]; then
  if [ "$#" -ne 3 ]; then
    echo "usage: $0 --verify-sha256 EXPECTED FILE" >&2
    exit 2
  fi
  verify_sha256 "$2" "$3"
  exit
fi

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

if [ "$#" -ne 1 ]; then
  echo "usage: $0 DEST" >&2
  exit 2
fi

DEST=$1
VERSION=$(python3 "$ROOT/scripts/release.py" dependency caresSource.version)
URL=$(python3 "$ROOT/scripts/release.py" dependency caresSource.url)
EXPECTED=$(python3 "$ROOT/scripts/release.py" dependency caresSource.sha256)
ARCHIVE="$DEST/c-ares-$VERSION.tar.gz"
SOURCE="$DEST/c-ares-$VERSION"
INSTALL="$DEST/install"

if [ -e "$ARCHIVE" ] || [ -e "$SOURCE" ] || [ -e "$INSTALL" ]; then
  echo "error: c-ares build destination is not empty: $DEST" >&2
  exit 1
fi

mkdir -p "$DEST"
curl -fsSL "$URL" -o "$ARCHIVE"
verify_sha256 "$EXPECTED" "$ARCHIVE"

tar -C "$DEST" -xzf "$ARCHIVE"
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2\n')
if (
    cd "$SOURCE"
    ./configure --disable-shared --enable-static --prefix="$INSTALL"
    make -j"$JOBS"
    make install
  ) >"$DEST/build.log" 2>&1
then
  :
else
  echo "error: the pinned c-ares build failed" >&2
  cat "$DEST/build.log" >&2
  exit 1
fi

test -f "$INSTALL/lib/pkgconfig/libcares.pc"
test -f "$INSTALL/lib/libcares.a"
printf '%s\n' "$INSTALL/lib/pkgconfig"
