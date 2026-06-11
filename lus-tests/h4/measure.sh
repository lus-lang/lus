#!/bin/sh
# A/B measurement helper for the Snow Leopard pass (not run in CI).
# Usage: ./lus-tests/h4/measure.sh <lus-binary> [runs]
# Runs each micro-benchmark <runs> times (default 3) from the repo root
# and prints the median TIME for each.
set -e
BIN="${1:?usage: measure.sh <lus-binary> [runs]}"
RUNS="${2:-3}"
for b in field method iter_ipairs iter_pairs strkey interp global gc_churn; do
  times=""
  for _ in $(seq "$RUNS"); do
    t=$("$BIN" "lus-tests/h4/bench_$b.lus" | awk '/^TIME/{print $2}')
    times="$times $t"
  done
  median=$(echo "$times" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  printf "%-12s %s\n" "$b" "$median"
done
