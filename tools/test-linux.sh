#!/bin/sh
# Runs the conformance suite on Linux in a local Lima VM, natively on
# aarch64 and, through qemu-user, on x86-64.
#
# Usage: tools/test-linux.sh [--quick] [--no-x64] [--riscv64] [--loong64] [--ppc64le] [--arm] [--s390x] [--strict]
#
# The script cross-builds the runtime for aarch64-linux and x86_64-linux,
# copies each binary with the test trees into the VM, and runs `lus test`
# there. The aarch64 binary runs the suite with the JIT off, with the
# default tiers, eager, and optimizing. The x86-64 binary runs under the
# qemu-user that the VM registers with binfmt_misc, so the processes the
# tests start run under it as well. It runs the default tiers and the
# optimizing tier, or only the default tiers with --quick. --riscv64,
# --loong64, --ppc64le, --arm, and --s390x each also cross-build a static musl
# binary for that architecture and run it under the qemu-user of the VM
# with the JIT off, with the default tiers, eager, baseline, and
# optimizing. Fedora registers no qemu-user for 32-bit ARM on an aarch64
# host, so --arm registers it for the running VM first. The VM is the one LUS_LIMA_VM names, `boring`
# by default, and must be running.
#
# The aarch64 runs decide the exit status. qemu-user emulates the memory
# map of a process, and glibc then reports native stack bounds that are
# larger than the stack qemu gives the program, so a long chain of direct
# calls in optimized code can overflow it (`jit_test.lus` under
# opt-eager). Tests that measure time also run slowly under emulation.
# The emulated runs therefore report their failures apart, and --strict
# makes them count as well. Native x86-64 Linux runs in CI. The emulated
# runs set LUS_EMULATED, which skips the one test whose bound qemu-user
# breaks by buffering sockets differently.
set -eu

vm="${LUS_LIMA_VM:-boring}"
quick=0
x64=1
extra=""
strict=0
for arg in "$@"; do
    case "$arg" in
        --quick) quick=1 ;;
        --no-x64) x64=0 ;;
        --riscv64) extra="$extra riscv64-linux-musl" ;;
        --loong64) extra="$extra loongarch64-linux-musl" ;;
        --ppc64le) extra="$extra powerpc64le-linux-musl" ;;
        --arm) extra="$extra arm-linux-musleabihf" ;;
        --s390x) extra="$extra s390x-linux-musl" ;;
        --strict) strict=1 ;;
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

# A cross build takes several gigabytes, so the builds run one at a time
# with one job each, once the machine has memory for them.
wait_for_memory() { sh "$root/tools/wait-for-memory.sh"; }
echo "building for aarch64-linux and x86_64-linux"
wait_for_memory
zig build -j1 -Doptimize=ReleaseSafe -Dtarget=aarch64-linux --prefix zig-out-linux-arm64
if [ "$x64" = 1 ]; then
    wait_for_memory
    zig build -j1 -Doptimize=ReleaseSafe -Dtarget=x86_64-linux --prefix zig-out-linux-x64
fi
for target in $extra; do
    wait_for_memory
    zig build -j1 -Doptimize=ReleaseSafe -Dtarget="$target" --prefix "zig-out-linux-${target%%-*}"
done

# The trees the conformance suite and the language server tests read.
stage="$(mktemp -d "${TMPDIR:-/tmp}/lus-linux.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
# COPYFILE_DISABLE keeps macOS tar from adding AppleDouble `._` files, which
# the runner would take for tests, and --no-xattrs keeps out the extended
# attributes that GNU tar warns about.
(cd "$root" && COPYFILE_DISABLE=1 tar -cf "$stage/trees.tar" --no-xattrs --exclude node_modules --exclude '._*' tests packages/language-server spec)

failed=0
emulated_failed=0
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
        [ "$arch" = arm64 ] || jit="$jit LUS_EMULATED=1"
        # The status of `lus test` decides, and the report shows every line
        # except the files that passed.
        if ! limactl shell "$vm" -- sh -c "cd ~/lus-linux-$arch/runtime && env $jit zig-out/bin/lus test --timeout 120 ../tests/conformance ../packages/language-server/tests > /tmp/lus-test-$arch.txt 2>&1; s=\$?; grep -a -v '^ok ' /tmp/lus-test-$arch.txt; exit \$s"; then
            if [ "$arch" = arm64 ]; then failed=1; else emulated_failed=1; fi
        fi
    done
}

run_suite arm64 off default eager opt-eager
if [ "$x64" = 1 ]; then
    if [ "$quick" = 1 ]; then run_suite x64 default; else run_suite x64 default opt-eager; fi
fi

case "$extra" in
    *arm-linux*)
        # The magic and mask of 32-bit little-endian ARM executables.
        limactl shell "$vm" -- sh -c 'test -e /proc/sys/fs/binfmt_misc/qemu-arm || printf ":qemu-arm:M::\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/usr/bin/qemu-arm-static:F\\n" | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null'
        ;;
esac
for target in $extra; do run_suite "${target%%-*}" off default eager baseline opt-eager; done

if [ "$emulated_failed" = 1 ]; then
    echo "an architecture under qemu-user had failures, which the notes at the top of tools/test-linux.sh explain"
    [ "$strict" = 1 ] && failed=1
fi
exit "$failed"
