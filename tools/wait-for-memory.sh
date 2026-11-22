#!/bin/sh
# Waits until the machine has memory for a large build, such as a wasm,
# cross, or stress build, which takes several gigabytes.
#
# Usage: tools/wait-for-memory.sh
#
# On macOS it waits while `memory_pressure` reports less than 30 percent of
# memory free, or while free swap is under 1 GB and falling. macOS keeps
# swap allocated long after the pressure that caused it is gone, so the
# share of swap in use says little on its own. Other systems pass at once.
# Builds still run one at a time, with -j1 for wasm and cross builds and
# -j2 otherwise.
set -eu

[ "$(uname)" = Darwin ] || exit 0
command -v memory_pressure >/dev/null 2>&1 || exit 0

free_percent() {
    memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'
}
swap_free_mb() {
    sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*free = ([0-9]+)(\.[0-9]+)?M.*/\1/'
}

previous=$(swap_free_mb)
while :; do
    pct=$(free_percent)
    swap=$(swap_free_mb)
    falling=0
    if [ -n "$swap" ] && [ -n "$previous" ] && [ "$swap" -lt 1024 ] && [ "$swap" -lt "$previous" ]; then falling=1; fi
    if [ -n "$pct" ] && [ "$pct" -ge 30 ] && [ "$falling" = 0 ]; then exit 0; fi
    [ -z "$pct" ] && exit 0
    echo "waiting for memory: ${pct}% free, ${swap:-?} MB of swap free"
    previous=$swap
    sleep 30
done
