#!/bin/sh
# Build lus with profile-guided optimization (PGO).
#
# Usage: tools/pgo-build.sh [builddir] [extra meson setup args...]
#        (default builddir: build-pgo)
# e.g.:  tools/pgo-build.sh build-release --buildtype=release
#
# Two-phase build: an instrumented binary runs a training workload
# (the H4 micro-benchmarks plus a slice of H1, covering the VM
# dispatch loop, tables, strings, calls, and the GC), then the
# profile is merged and the binary is rebuilt with branch layout
# optimized for those paths. Interpreters typically gain 10-20%.
#
# Works with clang (llvm-profdata required; on macOS it is found via
# xcrun) and gcc (gcda profiles need no merge step). Extra meson args
# apply only when the build directory is created fresh.
set -e
cd "$(dirname "$0")/.." # lus/
BUILDDIR="${1:-build-pgo}"
if [ $# -gt 0 ]; then shift; fi
ROOT="$(cd .. && pwd)" # repo root: tests expect it as cwd

if [ -d "$BUILDDIR/meson-private" ]; then
  meson configure "$BUILDDIR" -Db_pgo=generate
else
  meson setup "$BUILDDIR" -Db_pgo=generate "$@"
fi
meson compile -C "$BUILDDIR"

BIN="$PWD/$BUILDDIR/lus"
export LLVM_PROFILE_FILE="$PWD/$BUILDDIR/pgo-%p.profraw"

echo "== PGO training run =="
(
  cd "$ROOT"
  for b in field method iter_ipairs iter_pairs strkey interp global gc_churn; do
    "$BIN" "lus-tests/h4/bench_$b.lus" >/dev/null
  done
  for t in calls nextvar strings gc closure constructs events; do
    "$BIN" "lus-tests/h1/$t.lus" >/dev/null 2>&1 || true
  done
)

# clang writes .profraw files that must be merged; gcc's .gcda files
# are picked up by -fprofile-use directly.
if ls "$BUILDDIR"/pgo-*.profraw >/dev/null 2>&1; then
  PROFDATA="$(command -v llvm-profdata 2>/dev/null || xcrun -f llvm-profdata)"
  "$PROFDATA" merge -output="$BUILDDIR/default.profdata" "$BUILDDIR"/pgo-*.profraw
  rm -f "$BUILDDIR"/pgo-*.profraw
fi

meson configure "$BUILDDIR" -Db_pgo=use
meson compile -C "$BUILDDIR"

echo "== PGO smoke test =="
(cd "$ROOT" && "$BIN" "lus-tests/h1/calls.lus" >/dev/null)
echo "== PGO build ready: $BUILDDIR/lus =="
