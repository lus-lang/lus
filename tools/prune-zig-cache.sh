#!/bin/sh
# Keeps the Zig cache of this checkout under a size cap. Zig never removes
# anything from its cache, so without this every worktree grows by a few
# gigabytes a day.
#
# Usage: tools/prune-zig-cache.sh [checkout]
#
# The cap is LUS_ZIG_CACHE_CAP_GB gigabytes, 8 by default. Over the cap, the
# script removes compiled artifacts, oldest first, in passes of one week,
# three days, one day and one hour, until the cache is under three quarters
# of the cap. As a last resort it removes every artifact. Fetched packages
# (global/p) stay, since fetching them again needs the network. Removing an
# artifact that a later build needs only makes that build slower.
set -eu

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cache=$root/runtime/.zig-cache
[ -d "$cache" ] || exit 0
cap_gb=${LUS_ZIG_CACHE_CAP_GB:-8}
cap_kb=$((cap_gb * 1024 * 1024))
target_kb=$((cap_kb * 3 / 4))

size_kb() { du -sk "$cache" 2>/dev/null | cut -f1; }

# The artifact directories: o, h, z and tmp, in the cache and in global.
dirs() {
    for d in o h z tmp global/o global/h global/z global/tmp; do
        [ -d "$cache/$d" ] && echo "$cache/$d"
    done
}

kb=$(size_kb)
[ "$kb" -le "$cap_kb" ] && exit 0
echo "the Zig cache of $root holds $((kb / 1024)) MB, over the cap of ${cap_gb} GB"
for age in "+7" "+3" "+1" "+0"; do
    for d in $(dirs); do
        find "$d" -mindepth 1 -maxdepth 1 -mtime "$age" -exec rm -rf {} + 2>/dev/null || true
    done
    kb=$(size_kb)
    if [ "$kb" -le "$target_kb" ]; then
        echo "pruned the Zig cache to $((kb / 1024)) MB"
        exit 0
    fi
done
for d in $(dirs); do
    find "$d" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null || true
done
kb=$(size_kb)
if [ "$kb" -gt "$target_kb" ]; then
    for d in $(dirs); do rm -rf "$d"; done
    kb=$(size_kb)
fi
echo "pruned the Zig cache to $((kb / 1024)) MB"
