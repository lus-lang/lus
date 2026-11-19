#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-$REPO_ROOT/lus/build-qualification-thread}"

export CC="clang"
export LUS_TEST_SANITIZER="none"
export TSAN_OPTIONS="halt_on_error=1:abort_on_error=1:history_size=7:second_deadlock_stack=1"
export PYTHONPYCACHEPREFIX="$BUILD_DIR/python-cache"

if [ -f "$BUILD_DIR/build.ninja" ]; then
  meson setup "$BUILD_DIR" "$REPO_ROOT/lus" \
    --reconfigure \
    --buildtype=debug \
    -Db_lto=false \
    -Db_sanitize=thread \
    -Db_lundef=false
else
  meson setup "$BUILD_DIR" "$REPO_ROOT/lus" \
    --buildtype=debug \
    -Db_lto=false \
    -Db_sanitize=thread \
    -Db_lundef=false
fi

python3 "$REPO_ROOT/lus-tests/qualification.py" validate \
  --build-dir "$BUILD_DIR"
python3 "$REPO_ROOT/lus-tests/qualification.py" \
  validate-thread-sanitizer-build \
  --build-dir "$BUILD_DIR"

meson compile -C "$BUILD_DIR"

meson test -C "$BUILD_DIR" \
  --no-rebuild \
  --print-errorlogs \
  qualification/manifest \
  h1/worker \
  h1/worker2 \
  h2/worker \
  h2/worker-idle

python3 "$REPO_ROOT/lus-tests/qualification.py" validate-thread-results \
  --build-dir "$BUILD_DIR"
