#!/bin/sh
# Keeps the Zig cache under a size cap. Zig never removes anything from its
# cache, so without this it grows by gigabytes a day.
#
# Usage: tools/prune-zig-cache.sh [cache directory]
#
# The cache is the one that mise.toml points every checkout at,
# ~/.cache/lus-zig, unless an argument names another, such as the
# runtime/.zig-cache of a checkout from before the shared cache.
#
# The cap is LUS_ZIG_CACHE_CAP_GB gigabytes, 20 by default. Over the cap,
# the script removes compiled artifacts, oldest first, in passes of one
# week, three days, one day and one hour, until the cache is under three
# quarters of the cap. Builds share the cache, so it removes newer
# artifacts only while no build runs. Fetched packages (global/p) stay,
# since fetching them again needs the network. Removing an artifact that a
# later build needs only makes that build slower.
set -eu

cache=${1:-${HOME}/.cache/lus-zig}
[ -d "$cache" ] || exit 0
cap_gb=${LUS_ZIG_CACHE_CAP_GB:-20}
cap_kb=$((cap_gb * 1024 * 1024))
target_kb=$((cap_kb * 3 / 4))

size_kb() { du -sk "$cache" 2>/dev/null | cut -f1; }

# The artifact directories, in either layout: the shared cache keeps local/
# and global/, and a checkout's own cache keeps o, h and z beside global/.
dirs() {
    for d in o h z tmp local/o local/h local/z local/tmp global/o global/h global/z global/tmp; do
        [ -d "$cache/$d" ] && echo "$cache/$d"
    done
}

building() { pgrep -x zig >/dev/null 2>&1; }

kb=$(size_kb)
[ "$kb" -le "$cap_kb" ] && exit 0
echo "the Zig cache at $cache holds $((kb / 1024)) MB, over the cap of ${cap_gb} GB"
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
if building; then
    echo "pruned the Zig cache to $((kb / 1024)) MB; a build is running, so newer artifacts stay"
    exit 0
fi
for d in $(dirs); do
    find "$d" -mindepth 1 -maxdepth 1 -mmin +10 -exec rm -rf {} + 2>/dev/null || true
done
echo "pruned the Zig cache to $(($(size_kb) / 1024)) MB"
