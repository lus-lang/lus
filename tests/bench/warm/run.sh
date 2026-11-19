#!/bin/sh
# Measures warm starts: the same program as a cold binary chunk and as a
# warm one that carries the feedback of a profiling run.
#
# Usage: tests/bench/warm/run.sh [runs [functions [rounds]]]
#
# LUS is the Lus 2.0 binary (default runtime/zig-out/bin/lus). The script
# prints the best wall time of several runs of each chunk, and the
# in-program timeline of one run of each.

dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../../.." && pwd)
runs=${1:-10}
LUS=${LUS:-$root/runtime/zig-out/bin/lus}
work=$(mktemp -d "${TMPDIR:-/tmp}/lus-warm.XXXXXX")
trap 'rm -rf "$work"' EXIT

"$LUS" -P fs "$dir/gen.lus" "$work/startup.lus" $2 $3 || exit 1
"$LUS" compile -o "$work/cold.lusc" "$work/startup.lus" 2>/dev/null || exit 1
"$LUS" compile --profile -o "$work/warm.lusc" "$work/startup.lus" >/dev/null || exit 1

best() {
    perl -MTime::HiRes=time -e '
        my ($runs, @cmd) = @ARGV;
        my $best;
        for (1 .. $runs) {
            my $t = time;
            my $pid = fork();
            if ($pid == 0) {
                open(STDOUT, ">", "/dev/null");
                exec(@cmd) or exit 127;
            }
            waitpid($pid, 0);
            if ($? != 0) { print "-\n"; exit 0 }
            my $d = time - $t;
            $best = $d if !defined($best) || $d < $best;
        }
        printf "%.1f ms\n", $best * 1000;
    ' "$runs" "$@"
}

printf "%-12s %s\n" "interpreter" "$(LUS_JIT=off best "$LUS" "$work/cold.lusc")"
printf "%-12s %s\n" "cold" "$(best "$LUS" "$work/cold.lusc")"
printf "%-12s %s\n" "warm" "$(best "$LUS" "$work/warm.lusc")"
printf "%-12s %s\n" "empty" "$(best "$LUS" -e "")"
echo
printf "%-12s " "interpreter"; LUS_JIT=off "$LUS" "$work/cold.lusc"
printf "%-12s " "cold"; "$LUS" "$work/cold.lusc"
printf "%-12s " "warm"; "$LUS" "$work/warm.lusc"
