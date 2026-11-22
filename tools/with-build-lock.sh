#!/bin/sh
# Runs a command while holding the machine-wide build lock, so that the
# builds, gates and benchmarks of every checkout and worktree run one at a
# time. Each sandboxed session sees only its own processes, so a lock file
# is the one signal they all share.
#
# Usage: tools/with-build-lock.sh COMMAND [ARGUMENTS...]
#
# The lock is the directory ~/.cache/lus-zig/build.lock. A lock older than
# LUS_BUILD_LOCK_STALE_MIN minutes (90 by default) belongs to a holder that
# died, and the next caller takes it over. Before the command runs,
# tools/wait-for-memory.sh checks memory, swap and disk.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dir=${HOME}/.cache/lus-zig
lock=$dir/build.lock
stale=${LUS_BUILD_LOCK_STALE_MIN:-90}
mkdir -p "$dir"

waited=0
while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +"$stale" 2>/dev/null)" ]; then
        echo "taking over a build lock older than $stale minutes"
        rm -rf "$lock"
        continue
    fi
    if [ "$waited" -eq 0 ]; then
        echo "waiting for the build lock, held by: $(cat "$lock/owner" 2>/dev/null || echo unknown)"
    fi
    waited=$((waited + 1))
    sleep 15
done
trap 'rm -rf "$lock"' EXIT INT TERM HUP
echo "$(pwd): $*" > "$lock/owner"

sh "$here/wait-for-memory.sh"
"$@"
