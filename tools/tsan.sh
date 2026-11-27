#!/bin/sh
# Builds lus with ThreadSanitizer and runs the code that uses threads under
# it: the conformance suite interpreted, then tests/tsan/stress.lus, once in
# a plain ThreadSanitizer build and once in a build that collects at almost
# every allocation, where marking runs on several threads. Any report of
# ThreadSanitizer fails the run, and the reports stay in $TSAN_OUT
# (default: a temporary directory) for reading.
#
# The JIT stays off, since ThreadSanitizer does not see into the code it
# generates. Timing tests may fail under the slowdown of ThreadSanitizer,
# so only its reports and the stress program decide the result.
#
# Usage: tools/tsan.sh [-jN]
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
jobs="${1:--j2}"
out="${TSAN_OUT:-$(mktemp -d)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$root/runtime"

# On macOS the executable needs the ThreadSanitizer library, which the
# build leaves in its cache. A copy beside it, found through an rpath of
# @executable_path, also serves the lus processes that the tests start.
prepare() {
    prefix="$1"
    if [ "$(uname)" = Darwin ]; then
        lib=""
        for dir in "${ZIG_GLOBAL_CACHE_DIR:-}" "$HOME/.cache/lus-zig" "$HOME/.cache/zig" "$root/runtime/.zig-cache"; do
            [ -n "$dir" ] && [ -d "$dir" ] || continue
            lib="$(find "$dir" -name libclang_rt.tsan_osx_dynamic.dylib 2>/dev/null | head -n 1)"
            [ -n "$lib" ] && break
        done
        if [ -z "$lib" ]; then
            echo "tsan.sh: the ThreadSanitizer library is not in the Zig cache" >&2
            exit 1
        fi
        cp "$lib" "$prefix/bin/"
        install_name_tool -add_rpath @executable_path "$prefix/bin/lus" 2>/dev/null || true
        codesign -f -s - "$prefix/bin/lus" 2>/dev/null || true
    fi
}

zig build "$jobs" -Doptimize=ReleaseSafe -Dsanitize-thread=true --prefix zig-out-tsan
prepare zig-out-tsan
zig build "$jobs" -Doptimize=ReleaseSafe -Dsanitize-thread=true -Dgc-stress=97 --prefix zig-out-tsan-stress
prepare zig-out-tsan-stress

export LUS_JIT=off
# The runner of lus test exits without joining a worker that it left
# behind in a hung file, on purpose, and runner_test.lus tests exactly that,
# so thread leaks stay unreported. Data races are what the run looks for.
export TSAN_OPTIONS="halt_on_error=0 report_signal_unsafe=0 report_thread_leaks=0 log_path=$out/report"

status=0
zig-out-tsan/bin/lus test -P bytecode --timeout 600 ../tests/conformance ../packages/language-server/tests > "$out/suite.txt" 2>&1 || true
tail -n 1 "$out/suite.txt"
zig-out-tsan/bin/lus ../tests/tsan/stress.lus 200 || status=1
zig-out-tsan-stress/bin/lus ../tests/tsan/stress.lus 60 || status=1

reports="$(find "$out" -name 'report*' | wc -l | tr -d ' ')"
echo "$reports reports of ThreadSanitizer in $out"
if [ "$reports" != 0 ]; then
    for r in $(find "$out" -name 'report*'); do grep -E '^(WARNING|SUMMARY)' "$r"; done
    status=1
fi
exit "$status"
