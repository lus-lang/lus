# Platforms

Lus 2.0 compiles hot functions to machine code on aarch64 and x86-64 under macOS and Linux, and to WebAssembly modules in the WebAssembly build (`jit.md`, `opt.md`, `wasmjit.md`). Every other target runs the interpreter, which is the same code with the JIT compiled out. Windows on x86-64 and on arm64 ships in every release and runs interpreted. Lus adds both JIT tiers for every instruction set that the major JITs support: riscv64, loong64, ppc64le, 32-bit ARM, and s390x under Linux, Windows on x86-64 and arm64, and FreeBSD and Android on the instruction sets Lus already has. Each target has a gate that runs the whole conformance suite in every JIT mode on that target, natively or under emulation, before it merges.

## What other JITs support

The table lists the ports in the source trees of four production engines when Lus 2.0 chose its targets. A port maintained by a vendor rather than by the core team is marked as such.

| engine | instruction sets with a JIT | systems | everything else |
|---|---|---|---|
| V8 | x86-64, ia32, arm64, 32-bit ARM. Vendor ports: ppc64 and s390x (IBM), mips64el, loong64, riscv64. riscv32 is being removed. | Windows, macOS, Linux, Android, ChromeOS, Fuchsia, AIX | The `--jitless` mode interprets bytecode with no executable memory. |
| HotSpot | x86-64, aarch64, 32-bit ARM, ppc64 and ppc64le, s390x, riscv64. 32-bit x86 was removed in JDK 25 (JEP 503). | Linux, Windows (x86-64, aarch64), macOS (x86-64, aarch64), AIX | Zero, an interpreter in portable C++, runs on any Linux target. |
| LuaJIT | x86, x64, 32-bit ARM, arm64 (both byte orders), 32-bit PowerPC, MIPS32, MIPS64. riscv64 and loong64 exist as patches that distributions carry. | Windows (x86, x64, arm64), Linux, Android, the BSDs, macOS, iOS, game consoles | The interpreter is written in assembly per instruction set, so a new instruction set needs the whole VM. iOS runs the interpreter. |
| JavaScriptCore | x86-64, arm64 (with pointer authentication), 32-bit ARM (Thumb-2), riscv64 | macOS, iOS, Linux (GTK and WPE), Windows, PlayStation | CLoop, an interpreter in portable C++. MIPS and older ARM run it. |

Four facts from the table shape our order.

- Every engine compiles for x86-64 and arm64 on all three desktop systems. Lus covers two of the three.
- JavaScriptCore turned its JIT and its top tier on by default on Windows in late 2024, after the Windows port moved JIT code to the System V calling convention. That is the route this note takes for Windows on x86-64.
- riscv64 is the newest instruction set with a port in three of the four engines.
- 32-bit ARM survives in the engines that had it when it was common. JavaScriptCore keeps a second value representation for 32-bit targets. Its JIT tiers have separate code for it.

## What Lus supports today

| target | interpreter | baseline tier | optimizing tier | release artifact |
|---|---|---|---|---|
| aarch64 macOS | yes | yes | yes | yes |
| x86-64 macOS | yes | yes | yes | yes |
| aarch64 Linux | yes | yes | yes | yes, static musl |
| x86-64 Linux | yes | yes | yes | yes, static musl |
| x86-64 Windows | yes | | | yes |
| arm64 Windows | yes | | | yes |
| wasm32 WASI | yes | WebAssembly modules | | the npm package |

The native tiers depend on the target in six places.

- **The gate.** `jit.enabled` in `jit/jit.zig` turns the JIT on for aarch64 and x86-64 under macOS and Linux.
- **Executable memory.** `jit/mem.zig` maps chunks readable, writable, and executable with `mmap`. On Apple silicon the chunks carry `MAP_JIT` and the thread switches them to write mode while it copies code in. On aarch64 Linux the code is made visible to instruction fetch with the cache maintenance sequence in `syncCode`.
- **The calling convention.** Native code calls about forty runtime routines, each declared `callconv(.c)`. The runtime enters native code through the entry sequence, whose type is also `callconv(.c)`. `jit/x64.zig` emits System V calls. The optimizing tier allocates `rsi`, `rdi`, `xmm6`, and `xmm7` as registers that a called routine may clobber, which holds under System V.
- **The native stack.** `stackBounds` in `jit/jit.zig` asks the system for the stack of the thread on macOS and Linux, so that a chain of direct calls stops 128 KB above its low end (`opt.md`, "The stacks"). Elsewhere a chain gets 160 KB below its entry.
- **The word size.** A value is 16 bytes on every target, a 64-bit payload and a tag word. The WebAssembly build already runs it on a 32-bit target. The native tiers keep a payload in one machine register. The shared assembler interface has 64-bit loads, stores, and arithmetic as its primitives.
- **The byte order.** `Value.make` writes the tag as the low byte of the second 64-bit word, which is the `tag` field only on a little-endian target. The word of frame flags packs its bits the same way, and a compile-time assertion in `vm/state.zig` stops a big-endian build there. Every target Lus builds today is little-endian.

Native code carries no unwind information. Lus itself never unwinds through it, because errors are return values and the runtime uses no `setjmp` or `longjmp`. Debuggers, profilers, and crash reporters stop at the first frame of native code.

## Order

1. **riscv64, baseline tier.** A new instruction set that qemu-user runs in the lima VM, so every step has a local gate.
2. **riscv64, optimizing tier.**
3. **Windows on x86-64, then Windows on arm64.** Their gate is CI after the coordinator pushes, so this work runs while the next qemu target is built locally.
4. **loong64, both tiers.** It reuses the structure of the riscv64 assembler.
5. **ppc64le, both tiers.**
6. **32-bit ARM, both tiers.** It first needs the collector to build for a 32-bit target with threads, and an assembler interface that names the operations on 64-bit integers.
7. **s390x, both tiers.** The byte-order audit of the runtime comes first, gated by the interpreter under qemu. The big-endian JIT follows.
8. **FreeBSD and Android.** The gate opens on the instruction sets that already have backends, with the stack query of each system.

Every new instruction set adds an assembler behind the interface that `a64.zig` and `x64.zig` share, and nothing else in `emit.zig` or `opt/codegen.zig` beyond the register names and pools of that target. The interface already fuses comparisons with their branches (`jumpIf`, `jumpIfImm`), which matches every instruction set below that has no flags register. It already places constants in pools (`flushPool`).

## riscv64

riscv64 gets a third assembler, `jit/rv64.zig`. The target is RV64GC, the instruction set of every Linux distribution for riscv64. The Zba and Zbb extensions shorten address arithmetic and are used when the kernel reports them through `riscv_hwprobe`.

Three properties of the instruction set need work beyond the encodings.

- **Branch range.** A conditional branch reaches 4 KB in either direction, against 1 MB on aarch64. A conditional branch to a label that is not yet bound, or out of reach, is emitted as the inverted branch over a `jal`, which reaches 1 MB. A backward branch to a label in reach keeps the short form. The interval at which out-of-line code and constants are emitted shrinks to match.
- **Constants.** A 64-bit constant takes up to eight instructions to build. Addresses of runtime routines and of objects load from the pool with `auipc` and `ld`.
- **Instruction fetch.** `fence.i` makes new code visible to the hart that runs it alone. Installing code calls the `riscv_flush_icache` system call, which reaches every hart that runs the process.

The pinned registers are callee-saved `s` registers. The temporaries of the baseline tier are `t` registers. The optimizing tier allocates from the `a` and `t` registers and the float registers that the convention lets a callee clobber, which gives it more registers than aarch64.

## loong64

loong64 is little-endian and 64-bit, with fixed-width instructions and compare-and-branch instructions, which is the shape of riscv64. `jit/la64.zig` follows `rv64.zig` routine by routine. The branch relaxation and the placement of pools move into one module that both assemblers instantiate with their branch ranges: 128 KB for a two-register branch, 4 MB for a branch on zero, and 128 MB for `b` and `bl`. Pool loads use `pcaddu12i` and `ld.d`. The convention reserves `r21`, which no pool uses. New code becomes visible to instruction fetch after `ibar 0`, because the hardware keeps the instruction caches of the cores coherent with stores.

## ppc64le

ppc64le gets `jit/ppc64.zig` for the ELFv2 convention. Three properties need work beyond the encodings.

- **Calls.** A routine of the runtime expects its own address in `r12`, from which its global entry computes the table of contents in `r2`. Native code calls every routine through `mtctr r12` and `bctrl`. It never changes `r2`, which is the table of contents of the runtime itself.
- **Branch range.** A conditional branch reaches 32 KB, so a far conditional branch is the inverted branch over `b`, which reaches 32 MB, as on riscv64.
- **Condition registers.** A comparison writes a field of the condition register that the branch reads, so `jumpIf` emits a `cmpd` or `cmpld` into field 0 followed by `bc`.

New code becomes visible to instruction fetch after `dcbst`, `sync`, `icbi`, and `isync` over its cache lines.

## 32-bit ARM

32-bit ARM gets both tiers for ARMv7-A with VFPv3-D16, the target of every hard-float distribution. The value layout fits as it is, with a 64-bit payload and a tag word, since the WebAssembly build already runs it on a 32-bit target. A float lives in one double register. A pointer or a tag lives in one general register. Only a 64-bit integer needs a pair of general registers. The design keeps the second code path inside the assembler.

### Work before the JIT

The interpreter does not build for `arm-linux-musleabihf` yet. The parallel marker of the collector updates its mark bitmap with 64-bit atomic operations (`isMarkedSmallAtomic` and `setMarkSmallAtomic` in `vm/heap.zig`), which 32-bit ARM lacks. The WebAssembly build is single-threaded and never compiles them. Mark words of the native word size fix it. The interpreter then gets its own gate under `qemu-arm` before any JIT work.

### Two widths in the interface

The interface gains a second register type, `Pair`, for 64-bit integers, and a family of operations on it: loads and stores of a payload, moves, integer arithmetic, shifts, bitwise operations, and compare-and-branch. On a 64-bit target `Pair` is the same type as `Reg`. Each operation on it is the operation of the same name on a register, so `a64.zig`, `x64.zig`, `rv64.zig`, and the others gain only aliases. Every operation that takes a `Reg` works on a machine word: an address, an index, a count, a tag, or a pointer payload.

The templates and the code generator change in one way. A site that computes on an integer payload names a `Pair` register. Every other site keeps its `Reg`. The integer templates are a small part of `emit.zig`: arithmetic, integer comparisons, the numeric `for` loop, `mod` and `idiv`, and the bitwise operations. A site that loads a payload into a `Reg` and stores it unchanged moves a value from one slot to another, which `copy16` does on every target. Because the types differ on 32-bit ARM, the compiler rejects a 64-bit operation on a word register there. A build of that target therefore checks every site.

`a32.zig` implements a `Pair` as an even register and the odd register after it, which is the pair that `ldrd` and `strd` and the convention for 64-bit arguments use. The baseline tier pins the thread, the address of register 0, the index of that register, and the stop depth in four callee-saved registers. Its temporaries `t0` to `t2` are pairs and `t3` to `t6` are words, which uses the fourteen general registers. An addition is `adds` and `adc`. A multiplication is `umull` and two `mla`. A compare-and-branch compares the high words and branches, then compares the low words unsigned. Division calls the routine of the compiler runtime, because ARMv7-A has no 64-bit divide.

The optimizing tier allocates an integer value to one of four pairs. It allocates a pointer, a boolean, or a tag to a single register from the same registers. Floats use the sixteen double registers. Its passes and its representation are the same as on every target, since its values already carry their types.

A routine that native code calls takes a 64-bit integer only in a position that the AAPCS assigns to an even register pair. A compile-time check over the signatures of the routines enforces it.

The assembler emits the A32 encoding, whose conditional branches reach 32 MB. Addresses are 32 bits and load with `movw` and `movt`. New code becomes visible to instruction fetch through the `cacheflush` system call of ARM Linux.

## s390x

s390x is big-endian. The runtime assumes little-endian in two kinds of places.

- **Words written whole and read by field.** `Value.make` writes the tag as the low byte of the second word. The word of frame flags packs its bits the same way. The build stops at the assertion in `vm/state.zig`. The fix declares the fields of each such word in reverse order on a big-endian target, so that the field and the low byte of the word coincide on both byte orders. Native code reads fields at offsets from `@offsetOf`, so the templates follow the new layout.
- **Bytes that leave the process.** Binary chunks, bundles, `pack`, `vector`, hashing, and the network code read and write a fixed byte order. Each place that reads memory as a wider integer without naming its byte order is found by an audit of the casts and `readInt` calls, and is fixed to name it.

The interpreter passes the conformance suite under `qemu-s390x` before the JIT starts. `jit/s390x.zig` then targets z/Architecture as of z13. Every call reserves the 160-byte register save area that the convention gives each callee, which the entry sequence allocates once. Relative branches reach 64 KB. `brcl` reaches 4 GB, so far branches use it. The instruction fetch of z/Architecture is coherent with stores, so installing code needs no cache maintenance.

## Windows on x86-64

Windows is the largest desktop system by users. Lus already ships an interpreter build for it. The work is four changes in `jit/`, none of which touches the templates or the code generator.

### The calling convention

The convention of every routine that native code calls, and of the entry sequence, becomes `jit.cc`. It is `.x86_64_sysv` on Windows on x86-64 and `.c` everywhere else. Zig then compiles those routines, and every call from Zig into native code, with the System V convention on Windows as well. `emit.zig`, `x64.zig`, and `opt/codegen.zig` stay as they are. The optimizing tier keeps its seven integer and eight float registers. The Windows convention would make `rsi`, `rdi`, and `xmm6` through `xmm15` callee-saved and reserve 32 bytes of shadow space at every call.

The routines keep calling the rest of the runtime and the system with the Windows convention, which Zig handles at each call site. A call from Zig into the entry sequence saves `rsi`, `rdi`, and `xmm6` through `xmm15` around it, which costs a few stores per `execute`.

### Executable memory

`mem.zig` gains a Windows path. A chunk is reserved and committed with `VirtualAlloc` as `PAGE_READWRITE`. `install` switches the pages of the block to `PAGE_READWRITE` with `VirtualProtect`, copies the code, switches them back to `PAGE_EXECUTE_READ`, and calls `FlushInstructionCache`. A state and its arena belong to one thread, so switching pages never stops another thread that runs code from the same chunk. That is the reason the Apple silicon path can toggle per thread today.

A process that enables Arbitrary Code Guard cannot make pages executable. `VirtualProtect` then fails, so the state runs interpreted, as a system that refuses executable memory does today.

The same write then protect sequence, with `mprotect`, also serves OpenBSD, which refuses mappings that are writable and executable at once. We measure its cost on Linux before deciding whether Linux uses it too. Each installed function costs two system calls. A run compiles hundreds of functions, not millions, so the cost is expected to stay below the noise of a run.

### Unwind information

Each chunk registers a function table with `RtlAddGrowableFunctionTable`. A `RUNTIME_FUNCTION` entry covers each range of code whose stack pointer sits at a fixed distance from the frame of the entry sequence.

- Baseline code runs under the frame of the entry sequence: six pushes and a subtraction of 8. Its entries carry those unwind codes with a prologue of length zero, so the unwinder finds the caller of the entry sequence from any instruction of baseline code.
- A unit of optimized code also lowers the stack pointer by its block of the native stack. A body for direct entry pushes one native frame per activation. Each such body gets its own entry, which describes its own frame and leads to the frame below it.

The entries of a chunk stay sorted by address, because the arena reuses freed spans. A block that is freed or carved out of a reused span rewrites the sorted array of its chunk and registers it again, which happens at most once per compilation.

The exception dispatcher of Windows walks the stack with these tables. Without them a fault inside a routine that native code called ends the process without a usable report. WinDbg, Visual Studio, and the ETW profilers also stop at native code.

### The stack

`stackBounds` uses `GetCurrentThreadStackLimits` on Windows. Windows commits the stack of a thread one page at a time through a guard page, so code that lowers the stack pointer by more than 4 KB at once must touch each page in order. Baseline frames are small and fixed. The code generator of the optimizing tier emits a probe of every page when the native stack block of a unit exceeds 4 KB, as the `__chkstk` routine of the system compilers does.

### What CI must run

The `windows-2022` runner of `ci.yml` already runs `zig build test test-embed test-bundle test-check test-doc` and the conformance suite with `LUS_JIT` set to `off`, `eager`, and `opt-eager`. Those steps run interpreted today and test both tiers once the gate opens. The Windows work adds the following steps.

1. A step that fails unless native code runs: `LUS_JIT=eager lus -e "local function f() end f() assert(debug.jit(f))"`. A silent fallback to the interpreter would otherwise pass every other step.
2. The conformance suite with `LUS_JIT=baseline`, and with `LUS_JIT=opt-eager LUS_JIT_DIRECT=1024`, which ends every chain of direct calls after a few activations and so exercises the probes and the unwinding of exits.
3. A unit test in `jit/tests.zig` that calls `RtlVirtualUnwind` from a routine that native code called, at each kind of frame, and checks that the walk reaches the caller of the entry sequence. The encoder of the unwind codes is a pure function, so byte-level tests of it run on every host.
4. A `-Dgc-stress=97 -Dgc-verify=true` build that runs the conformance suite with `LUS_JIT=eager` and `LUS_JIT=opt-eager`, and the differential tester with its default seeds. Both join the `windows-2022` entry of the nightly matrix.

Locally, `zig build -Dtarget=x86_64-windows` and `zig build test -Dtarget=x86_64-windows` check that everything compiles. The macOS and Linux gates check that the shared code is unchanged.

## Windows on arm64

The arm64 convention of Windows is the standard AAPCS64 with `x18` reserved for the thread environment block. `a64.zig` and the register pools of both tiers already leave `x18` alone, because macOS reserves it too, so the emitter needs no change. A test asserts that no pool, scratch, or pinned register is `x18`. Two pieces of work remain after Windows on x86-64. The unwind information takes its arm64 form, which packs its codes differently and describes `stp` pairs. `FlushInstructionCache` replaces `syncCode`.

CI adds a `windows-11-arm` runner to the runtime matrix with the same steps as `windows-2022`. GitHub provides that runner free of charge for public repositories. A private repository needs a paid arm64 runner. Until one exists, the target is cross-built only and its JIT stays off.

## FreeBSD and Android

FreeBSD and Android run the instruction sets that already have backends. The gate opens for them with the stack query of each system in `stackBounds`: `pthread_attr_get_np` on FreeBSD and `pthread_getattr_np` in the C library of Android. The executable memory path of Linux works on both. FreeBSD is checked in CI by a job that runs the conformance suite in a FreeBSD virtual machine on a Linux runner. Android is cross-built in CI and checked on an emulator image when one is available to the runner.

iOS and the game consoles refuse executable memory to ordinary programs, so the only native code they can run is code compiled ahead of time.

## Testing each target

Every Linux target is gated locally by a static musl build under qemu-user in the lima VM "boring", with the conformance suite under `LUS_JIT` set to `off`, the default, `eager`, `baseline`, and `opt-eager`, and with a `-Dgc-stress=97 -Dgc-verify=true` build under `eager` and `opt-eager`. CI cross-builds every target on every pull request. A nightly Linux job runs the same suite under `qemu-user-static` for each of them. The encodings of each assembler get byte-level unit tests against the output of a system assembler, as `a64.zig` and `x64.zig` have.

| target | local gate | CI |
|---|---|---|
| riscv64 | `qemu-riscv64` in the VM | nightly qemu job, cross-build on every pull request |
| loong64 | `qemu-loongarch64` in the VM | the same |
| ppc64le | `qemu-ppc64le` in the VM | the same |
| 32-bit ARM | `qemu-arm` in the VM | the same |
| s390x | `qemu-s390x` in the VM | the same |
| Windows x86-64 | cross-build only | `windows-2022`, after a push |
| Windows arm64 | cross-build only | `windows-11-arm`, after a push |
| FreeBSD | cross-build only | a FreeBSD virtual machine job |
| Android | cross-build only | cross-build, emulator when available |

qemu-user overstates the stack of the main thread, which made chains of direct calls overrun it in the x86-64 gate. `stackBounds` takes the smaller of the size that `pthread_getattr_np` reports and the `RLIMIT_STACK` limit for the main thread, which lets the qemu gates run direct calls as native systems do. Until that change lands, the qemu gates run with `LUS_JIT_DIRECT=off` as well. qemu does not model the memory ordering or the instruction fetch of real hardware, so each qemu target is confirmed on native hardware, such as a cloud server, before it is announced.

The interpreters of riscv64, ppc64le, and loong64 build from the same sources and pass the conformance suite under qemu-user in the VM, 6325 tests each. The one failure in each run is `a_slow_reader_loses_its_connection_test` in `serve_test.lus`, the known artifact of emulated socket buffers that the x86-64 gate shares. A failure in the gate of a new JIT on those targets therefore points at the new tier.

## Ahead-of-time compilation

Ahead-of-time compilation follows the platforms and has its own note, `aot.md`. Two facts from the platform work feed it. Native code embeds the absolute addresses of runtime routines, constants, and inline cache entries, so code compiled ahead of time needs relocations that the startup of the program resolves. The unwind tables of Windows and the constant pools of the new assemblers make the emitter produce a code object with metadata next to its bytes. An executable compiled ahead of time stores that object together with its relocations.
