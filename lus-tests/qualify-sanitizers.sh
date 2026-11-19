#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-$REPO_ROOT/lus/build-qualification-sanitize}"
EVIDENCE_PATH="${2:-$BUILD_DIR/sanitizer-qualification.json}"

export CC="clang"
export LUS_TEST_SANITIZER="address"
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1:print_summary=1"
export LSAN_OPTIONS="exitcode=23:print_suppressions=1"
export UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1:print_stacktrace=1"
export PYTHONPYCACHEPREFIX="$BUILD_DIR/python-cache"

if [ -f "$BUILD_DIR/build.ninja" ]; then
  meson setup "$BUILD_DIR" "$REPO_ROOT/lus" \
    --reconfigure \
    --buildtype=debug \
    -Db_lto=false \
    -Db_sanitize=address,undefined \
    -Db_lundef=false
else
  meson setup "$BUILD_DIR" "$REPO_ROOT/lus" \
    --buildtype=debug \
    -Db_lto=false \
    -Db_sanitize=address,undefined \
    -Db_lundef=false
fi

python3 "$REPO_ROOT/lus-tests/qualification.py" validate-sanitizer-build \
  --build-dir "$BUILD_DIR"

meson compile -C "$BUILD_DIR"

LEAK_PROBE_PATH="$BUILD_DIR/leak-detection-probe.log"
LEAK_PROBE_BINARY="$BUILD_DIR/leak-detection-probe"
"$CC" \
  -std=c11 \
  -g \
  -O0 \
  -Wall \
  -Wextra \
  -Werror \
  -fno-omit-frame-pointer \
  -fsanitize=address \
  "$REPO_ROOT/lus-tests/sanitizer/leak_probe.c" \
  -o "$LEAK_PROBE_BINARY"
set +e
ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=0:allocator_may_return_null=1:print_summary=1" \
LSAN_OPTIONS="exitcode=23:print_suppressions=1" \
  "$LEAK_PROBE_BINARY" \
  >"$LEAK_PROBE_PATH" 2>&1
LEAK_PROBE_STATUS=$?
set -e
printf '\nexit_status=%s\n' "$LEAK_PROBE_STATUS" >>"$LEAK_PROBE_PATH"

if [ "$(uname -s)" = "Darwin" ] && \
  [ "$LEAK_PROBE_STATUS" -ne 0 ] && \
  grep -Fq "detect_leaks is not supported on this platform" "$LEAK_PROBE_PATH"; then
  echo "Leak detection was requested and rejected by the Apple AddressSanitizer runtime." >&2
  echo "The full macOS sanitizer suite will run with leak detection disabled." >&2
  export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1:print_summary=1"
elif [ "$LEAK_PROBE_STATUS" -eq 23 ] && \
  grep -Fq "ERROR: LeakSanitizer: detected memory leaks" "$LEAK_PROBE_PATH" && \
  grep -Fq "SUMMARY: AddressSanitizer:" "$LEAK_PROBE_PATH"; then
  echo "LeakSanitizer detected the intentional leak with the expected report." >&2
else
  cat "$LEAK_PROBE_PATH" >&2
  echo "LeakSanitizer intentional-leak probe failed." >&2
  exit 1
fi

meson test -C "$BUILD_DIR" \
  --no-rebuild \
  --print-errorlogs \
  --suite h1 \
  --suite h2

python3 "$REPO_ROOT/lus-tests/qualification.py" sanitizer-evidence \
  --build-dir "$BUILD_DIR" \
  --leak-probe "$LEAK_PROBE_PATH" \
  --output "$EVIDENCE_PATH"
