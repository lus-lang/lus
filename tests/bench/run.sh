#!/bin/sh
# Runs every benchmark in this directory under each available runtime and
# prints the best wall time of several runs as a table.
#
# Usage: tests/bench/run.sh [runs]
#
# Runtimes come from the environment. LUS is the Lus 2.0 binary (default
# runtime/zig-out/bin/lus), LEGACY is the 1.7 binary (default
# legacy/lus/build/lus), and LUAJIT is a LuaJIT binary (default luajit on
# the PATH). Lus runs twice, with its JIT on and with LUS_JIT=off, and
# LuaJIT runs twice, with -joff and with its JIT. A runtime that is
# missing, or that fails on a benchmark, shows a dash.

dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
runs=${1:-3}
LUS=${LUS:-$root/runtime/zig-out/bin/lus}
LEGACY=${LEGACY:-$root/legacy/lus/build/lus}
LUAJIT=${LUAJIT:-$(command -v luajit 2>/dev/null)}

# Prints the best wall time in seconds of $runs runs of the command, or a
# dash when the command is missing or fails. The first argument is the
# value of LUS_JIT for the command, or "default" to leave it unset.
best() {
    perl -MTime::HiRes=time -e '
        my ($runs, $jit, @cmd) = @ARGV;
        if ($jit eq "default") { delete $ENV{LUS_JIT} } else { $ENV{LUS_JIT} = $jit }
        my $best;
        for (1 .. $runs) {
            my $t = time;
            my $pid = fork();
            if ($pid == 0) {
                open(STDOUT, ">", "/dev/null");
                open(STDERR, ">", "/dev/null");
                exec(@cmd) or exit 127;
            }
            waitpid($pid, 0);
            if ($? != 0) { print "-\n"; exit 0 }
            my $d = time - $t;
            $best = $d if !defined($best) || $d < $best;
        }
        printf "%.3f\n", $best;
    ' "$runs" "$@"
}

printf "%-10s %10s %10s %10s %14s %10s %10s\n" benchmark lus "lus off" legacy "luajit -joff" luajit lus/legacy
for f in "$dir"/*.lus; do
    name=$(basename "$f" .lus)
    if [ -x "$LUS" ]; then
        a=$(best default "$LUS" "$f")
        o=$(best off "$LUS" "$f")
    else
        a=-
        o=-
    fi
    if [ -x "$LEGACY" ]; then b=$(best default "$LEGACY" "$f"); else b=-; fi
    # LuaJIT runs the Lua version of a benchmark when one exists, because
    # some benchmarks use Lus syntax.
    lf="$dir/lua/$name.lua"
    [ -f "$lf" ] || lf=$f
    if [ -n "$LUAJIT" ] && [ -x "$LUAJIT" ]; then
        c=$(best default "$LUAJIT" -joff "$lf")
        j=$(best default "$LUAJIT" "$lf")
    else
        c=-
        j=-
    fi
    if [ "$a" != - ] && [ "$b" != - ]; then
        r=$(echo "scale=2; $a / $b" | bc)
    else
        r=-
    fi
    printf "%-10s %10s %10s %10s %14s %10s %10s\n" "$name" "$a" "$o" "$b" "$c" "$j" "$r"
done
