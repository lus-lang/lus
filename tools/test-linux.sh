#!/bin/sh
# Runs the conformance suite on Linux in a local Lima VM, natively on
# aarch64 and, through qemu-user, on x86-64.
#
# Usage: tools/test-linux.sh [--quick] [--no-x64]
#
# The script cross-builds the runtime for aarch64-linux and x86_64-linux,
# copies each binary with the test trees into the VM, and runs `lus test`
# there. The aarch64 binary runs the suite with the JIT off, with the
# default tiers, eager, and optimizing. The x86-64 binary runs under the
# qemu-user that the VM registers with binfmt_misc, so the processes the
# tests start run under it as well. It runs the default tiers and the
# optimizing tier, or only the default tiers with --quick. The VM is the
# one LUS_LIMA_VM names, `boring` by default, and must be running.
set -eu

vm="${LUS_LIMA_VM:-boring}"
quick=0
x64=1
for arg in "$@"; do
    case "$arg" in
        --quick) quick=1 ;;
        --no-x64) x64=0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/runtime"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"

if ! limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -q "^$vm Running$"; then
    echo "the Lima VM '$vm' is not running; start it with: limactl start $vm" >&2
    exit 2
fi

echo "building for aarch64-linux and x86_64-linux"
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux --prefix zig-out-linux-arm64
[ "$x64" = 1 ] && zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux --prefix zig-out-linux-x64

# The trees the conformance suite and the language server tests read.
stage="$(mktemp -d "${TMPDIR:-/tmp}/lus-linux.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
(cd "$root" && tar -cf "$stage/trees.tar" --exclude node_modules tests packages/language-server spec)

failed=0
run_suite() {
    arch="$1"; shift
    bin="zig-out-linux-$arch/bin/lus"
    echo "copying the $arch binary and the tests to $vm"
    limactl shell "$vm" -- sh -c "rm -rf ~/lus-linux-$arch && mkdir -p ~/lus-linux-$arch/runtime/zig-out/bin"
    limactl shell "$vm" -- sh -c "tar -xf - -C ~/lus-linux-$arch" < "$stage/trees.tar"
    limactl shell "$vm" -- sh -c "cat > ~/lus-linux-$arch/runtime/zig-out/bin/lus && chmod +x ~/lus-linux-$arch/runtime/zig-out/bin/lus" < "$bin"
    for mode in "$@"; do
        echo "== $arch, LUS_JIT=$mode"
        jit="LUS_JIT=$mode"
        [ "$mode" = default ] && jit=""
        # The status of `lus test` decides, and the report shows every line
        # except the files that passed.
        if ! limactl shell "$vm" -- sh -c "cd ~/lus-linux-$arch/runtime && env $jit zig-out/bin/lus test --timeout 120 ../tests/conformance ../packages/language-server/tests > /tmp/lus-test-$arch.txt 2>&1; s=\$?; grep -v '^ok ' /tmp/lus-test-$arch.txt; exit \$s"; then
            failed=1
        fi
    done
}

run_suite arm64 off default eager opt-eager
if [ "$x64" = 1 ]; then
    if [ "$quick" = 1 ]; then run_suite x64 default; else run_suite x64 default opt-eager; fi
fi

exit "$failed"
