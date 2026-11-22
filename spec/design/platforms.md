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
| riscv64 Linux | yes | yes | yes | not yet |
| loong64 Linux | yes | yes | yes | not yet |
| ppc64le Linux | yes | yes | yes | not yet |
| x86-64 Linux | yes | yes | yes | yes, static musl |
| x86-64 Windows | yes | | | yes |
| arm64 Windows | yes | | | yes |
| 32-bit ARM Linux | yes | | | not yet |
| s390x Linux | yes | yes | yes | not yet |
| FreeBSD (aarch64, x86-64) | yes | yes | yes | not yet |
| wasm32 WASI | yes | WebAssembly modules | | the npm package |

The native tiers depend on the target in six places.

- **The gate.** `jit.enabled` in `jit/jit.zig` turns the JIT on for aarch64 and x86-64 under macOS and Linux.
- **Executable memory.** `jit/mem.zig` maps chunks readable, writable, and executable with `mmap`. On Apple silicon the chunks carry `MAP_JIT` and the thread switches them to write mode while it copies code in. On aarch64 Linux the code is made visible to instruction fetch with the cache maintenance sequence in `syncCode`.
- **The calling convention.** Native code calls about forty runtime routines, each declared `callconv(.c)`. The runtime enters native code through the entry sequence, whose type is also `callconv(.c)`. `jit/x64.zig` emits System V calls. The optimizing tier allocates `rsi`, `rdi`, `xmm6`, and `xmm7` as registers that a called routine may clobber, which holds under System V.
- **The native stack.** `stackBounds` in `jit/jit.zig` asks the system for the stack of the thread on macOS and Linux, so that a chain of direct calls stops 128 KB above its low end (`opt.md`, "The stacks"). Elsewhere a chain gets 160 KB below its entry.
- **The word size.** A value is 16 bytes on every target, a 64-bit payload and a tag word. The WebAssembly build already runs it on a 32-bit target. The native tiers keep a payload in one machine register. The shared assembler interface has 64-bit loads, stores, and arithmetic as its primitives.
- **The byte order.** `Value.make` writes the tag as the low byte of the second 64-bit word, which is the `tag` field only on a little-endian target. The word of frame flags packs its bits the same way. A compile-time assertion in `vm/state.zig` stops a big-endian build there. Every target Lus builds today is little-endian.

Native code carries no unwind information. Lus itself never unwinds through it, because errors are return values and the runtime uses no `setjmp` or `longjmp`. Debuggers, profilers, and crash reporters stop at the first frame of native code.

## Order

1. **riscv64, baseline tier.** A new instruction set that qemu-user runs in the lima VM, so every step has a local gate.
2. **riscv64, optimizing tier.**
3. **Windows on x86-64, then Windows on arm64.** Their gate is CI after the coordinator pushes, so this work runs while the next qemu target is built locally.
4. **loong64, both tiers.** It reuses the structure of the riscv64 assembler.
5. **ppc64le, both tiers.**
6. **32-bit ARM, both tiers.** It first needs the collector to build for a 32-bit target with threads, and an assembler interface that names the loads and stores of pointer-sized words.
7. **s390x, both tiers.** The byte-order audit of the runtime comes first, gated by the interpreter under qemu. The big-endian JIT follows.
8. **FreeBSD and Android.** The gate opens on the instruction sets that already have backends, with the stack query of each system.

Every new instruction set adds an assembler behind the interface that `a64.zig` and `x64.zig` share, and nothing else in `emit.zig` or `opt/codegen.zig` beyond the register names and pools of that target. The interface already fuses comparisons with their branches (`jumpIf`, `jumpIfImm`), which matches every instruction set below that has no flags register. It already places constants in pools (`flushPool`).

The routines that native code calls take every integer as a full word, a pointer, or a value. The conventions of riscv64, loong64, and s390x extend a 32-bit argument to 64 bits by its sign, ppc64le by its type, and the compiled routine relies on that extension. On riscv64 a step routine compared an instruction word whose top bit was set, passed zero-extended, against a sign-extended constant, and misread it. Wide parameters keep every caller in native code free of that rule on every target.

## riscv64

riscv64 gets a third assembler, `jit/rv64.zig`. The target is RV64GC, the instruction set of every Linux distribution for riscv64. The Zba and Zbb extensions shorten address arithmetic and are used when the kernel reports them through `riscv_hwprobe`.

Three properties of the instruction set need work beyond the encodings.

- **Branch range.** A conditional branch reaches 4 KB in either direction, against 1 MB on aarch64. A conditional branch to a label that is not yet bound, or out of reach, is emitted as the inverted branch over a `jal`, which reaches 1 MB. A backward branch to a label in reach keeps the short form. A `jal` reaches 1 MB, and a function of 30 000 instructions needs more. The emitter flushes its out-of-line code and its pool every 64 KB of straight-line code, at a point execution never reaches, and each flush writes an island for every `jal` since the previous flush whose label is unbound or out of reach: an `auipc` and a `jalr` that reach 2 GB. The `jal` jumps to its island. Every jump therefore stays one instruction, which the call entry relies on when it computes the return address of its caller from the length of the jump that follows the call.
- **Constants.** A 64-bit constant takes up to eight instructions to build. Addresses of runtime routines and of objects load from the pool with `auipc` and `ld`.
- **Instruction fetch.** `fence.i` makes new code visible to the hart that runs it alone. Installing code calls the `riscv_flush_icache` system call, which reaches every hart that runs the process.

The pinned registers are callee-saved `s` registers. The temporaries of the baseline tier are `t` registers. The assembler keeps `a6` and `a7` as its own scratch registers. The optimizing tier allocates 13 integer registers, `a0` to `a5` and `t0` to `t6`, and 16 float registers, `fa0` to `fa7` and `ft0` to `ft7`, as many as on aarch64. Its scratch registers are `s5` to `s7`, which the entry sequence saves.

## loong64

loong64 is little-endian and 64-bit, with fixed-width instructions and compare-and-branch instructions, which is the shape of riscv64. `jit/la64.zig` follows `rv64.zig` routine by routine. A branch on two registers reaches 128 KB, a branch on zero 4 MB, and `b` and `bl` 128 MB. A conditional branch to a label that is unbound or out of reach is the inverted branch over a `b`, and `b` reaches every label of a function, so loong64 needs no islands. Pool loads use `pcaddu12i` and `ld.d`. Integer and float conversions run inside the float registers, so `floatToInt` goes through `ft13`, the float scratch register of the assembler. The convention reserves `r21`, which no pool uses. The optimizing tier allocates 15 integer registers, `a0` to `a7` and `t0` to `t6`, and 16 float registers. New code becomes visible to instruction fetch after `ibar 0`, because the hardware keeps the instruction caches of the cores coherent with stores.

## ppc64le

ppc64le gets `jit/ppc64.zig` for POWER8, the oldest processor that runs a little-endian distribution, and the ELFv2 convention. Four properties of the target shape it.

- **Calls.** A routine of the runtime expects its own address in `r12`, from which its global entry computes the table of contents in `r2`. Native code calls every routine through `r12`, `mtctr`, and `bctrl`, and it never changes `r2`, which is the table of contents of the runtime itself.
- **The frame header.** A called routine stores the link register, and may store the condition register, into the 32-byte header at the bottom of the frame of its caller. The stack pointer that the emitter and the code generator see sits 32 bytes above `r1`, so every frame that native code opens keeps its header free for the routines it calls. Every use of the stack pointer goes through a memory operand, `leaSp`, `setSp`, `moveSp`, or `saveLink`, so the offset lives in the assembler alone.
- **Registers.** The convention leaves too few volatile registers outside the six arguments, so the temporaries of the baseline tier are the callee-saved `r21` to `r27`, which the entry sequence saves with the pinned registers. The optimizing tier allocates 15 integer registers, `r3` to `r10` and `r21` to `r27`, and 11 float registers. `r0` reads as zero as a base, so it serves only the link register moves and one multiplication.
- **Branch range.** A conditional branch reaches 32 KB, so a branch to a label that is unbound or out of reach is the inverted branch over `b`, which reaches 32 MB, as on loong64. A comparison writes condition field 0, and the branch reads one of its bits.

POWER8 has no pc-relative load, so a constant builds in place in at most five instructions and the assembler keeps no pool. It has no remainder instruction either, so a remainder is a division, a multiplication, and a subtraction. Integer and float conversions use `mtvsrd`, `mfvsrd`, `fcfid`, and `fctidz`. New code becomes visible to instruction fetch after `dcbst`, `sync`, `icbi`, `sync`, and `isync` over its cache lines.

## 32-bit ARM

32-bit ARM gets both tiers for ARMv7-A with VFPv3-D16, the target of every hard-float distribution. The value layout fits as it is, with a 64-bit payload and a tag word, since the WebAssembly build already runs it on a 32-bit target. The design keeps the second code path inside the assembler.

### Work before the JIT

The interpreter builds for `arm-linux-musleabihf` and passes the conformance suite under `qemu-arm` in the VM. Two places used 64-bit atomic operations, which 32-bit ARM lacks. The parallel marker of the collector updates its mark bitmap, whose words stay 64 bits wide for the sweep, through the 32-bit half of the word that holds the bit (`markWord` in `vm/heap.zig`). The sequence counter of the debug adapter is a word-sized atomic. `tools/test-linux.sh --arm` runs the gate.

### Pairs inside the assembler

Every register of the interface is a pair of 32-bit registers inside `a32.zig`: a low word and a high word. Each operation of the interface keeps its 64-bit meaning, so an addition is `adds` and `adc`, a multiplication is `umull` and two `mla`, a shift spans both words, and a compare-and-branch compares the high words and then the low words unsigned. The templates and the code generator therefore keep one code path for every target.

The one distinction they gain is the width of a word in memory. A pointer, a count, or a stack index is 4 bytes on a 32-bit target, and a payload or a 64-bit counter is 8. The interface gains `loadWord` and `storeWord`, which are `load64` and `store64` on a 64-bit target. Every site that loads or stores a pointer-sized field names them. A word loaded into a pair clears its high half. A payload that holds a pointer keeps its high word zero, which is what `Value.make` writes, so a pointer read from a payload is its low word.

A pair costs two registers, of the fourteen that 32-bit ARM has. The pinned registers keep their single registers, because each holds a pointer or an index: the thread and the address of register 0 in two callee-saved registers, and the index of register 0 and the stop depth in slots of the native frame, which the assembler loads where an instruction names them. The temporaries `t0` to `t3` are register pairs. The temporaries `t4` to `t6`, the fifth and sixth argument, and the pool registers of the optimizing tier beyond those pairs are slots of the native frame, which the assembler moves through a scratch pair. Code that uses them runs slower than code in registers. Code that uses only the first temporaries runs at the speed of register pairs. Floats use the sixteen double registers of VFPv3-D16 directly.

A routine of the runtime takes words as arguments (see "Order"). The first four arguments of AAPCS travel in `r0` to `r3`, so the assembler passes the low word of each argument pair. Division calls the routine of the compiler runtime, because ARMv7-A has no 64-bit divide.

The assembler emits the A32 encoding, whose conditional branches reach 32 MB. Addresses are 32 bits and load with `movw` and `movt`. New code becomes visible to instruction fetch through the `cacheflush` system call of ARM Linux.

A frame of a 32-bit target is padded to 64 bytes, so that native code finds a frame with a shift and an add on every target.

## s390x

s390x is big-endian. The runtime assumes little-endian in two kinds of places.

- **Words written whole and read by field.** `Value.make` writes a value as two 64-bit words, and the tag is the first byte of the second word, so `Value.tagWord` puts the tag in the low byte of that word on a little-endian target and in its high byte on a big-endian one. The flags of a plain call are the last two bytes of the flags word of a frame, so `CallFlags.frameFlags` shifts them to the top of the word on a little-endian target and swaps them into its bottom on a big-endian one. `Frame.flagMask` reads its mask in the byte order of the target, because a cast of a byte array to an integer at compile time reads it little-endian.
- **Bytes that leave the process.** Binary chunks, bundles, `pack`, `vector`, hashing, and the network code pass their conformance tests on s390x unchanged, so the byte order of what they read and write does not depend on the target.

The interpreter passes the conformance suite under `qemu-s390x` with those three changes, and `tools/test-linux.sh --s390x` runs it. `jit/s390x.zig` targets z/Architecture and its ELF convention, with the register roles of `x64.zig`: the temporaries share the argument registers, and the optimizing tier allocates the seven temporaries in the order of the x86-64 pool, so that its registers overlap the argument registers as they do there. Four properties of the target shape it.

- **The save area.** Every call gives the routine it calls a register save area of 160 bytes at the bottom of the frame of the caller. The stack pointer that native code sees sits 160 bytes above `r15`, as on ppc64le with its 32-byte header.
- **Results of two words.** A routine that returns a structure of more than 8 bytes, such as `jit.Target`, returns it through memory whose address its caller passes in `r2`. The interface gains `callPair`, which is `call` on every other target. On s390x it moves the arguments up a register, passes 16 bytes of new frame, and loads the two words into the result registers.
- **Register 0.** `r0` reads as zero as a base or an index, so it serves only as data. A call loads its target into `r14`, the link register, and calls through it, so the assembler needs no base register of its own. A division uses the pair `r0` and `r1`. `r1` is also the scratch register of the optimizing tier, which every target lets a call clobber.
- **Branches.** A compare-and-branch instruction reaches 64 KB, and a comparison followed by `brcl` reaches 4 GB, which covers every function, so no branch needs an island. `jmp` is always `brcl`, which gives the jump after a call entry the fixed length that `linkPastJump` counts.

The templates write a tag in three ways. On a big-endian target the tag belongs in the high byte of its word. A constant tag goes through `Value.tagWord`. A tag in a register goes through `storeTag`. A payload and a tag go through `storeValue`. Both are `store64` and `storePair64` on a little-endian target and store the tag byte at the start of its word on s390x. A tag that native code passes to the runtime is loaded as its byte. Frames need no change, because native code writes their fields one by one or as words that the runtime computes in the byte order of the target. The instruction fetch of z/Architecture follows stores, so installing code needs no cache maintenance.

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
4. A `-Dgc-stress=1 -Dgc-verify=true` build that runs the conformance suite with `LUS_JIT` set to `off`, `eager`, and `opt-eager`, in the `windows-2022` entry of the nightly stress job. The differential tester starts its programs through a POSIX shell, so it joins the Windows runs once it starts them directly.

Locally, `zig build -Dtarget=x86_64-windows` and `zig build test -Dtarget=x86_64-windows` check that everything compiles. The macOS and Linux gates check that the shared code is unchanged.

## Windows on arm64

The arm64 convention of Windows is the standard AAPCS64 with `x18` reserved for the thread environment block. `a64.zig` and the register pools of both tiers already leave `x18` alone, because macOS reserves it too, so the emitter needs no change. A test asserts that no pool, scratch, or pinned register is `x18`. Two pieces of work remain after Windows on x86-64. The unwind information takes its arm64 form, which packs its codes differently and describes `stp` pairs. `FlushInstructionCache` replaces `syncCode`.

CI adds a `windows-11-arm` runner to the runtime matrix with the same steps as `windows-2022`. GitHub provides that runner free of charge for public repositories. A private repository needs a paid arm64 runner. Until one exists, the target is cross-built only and its JIT stays off.

## FreeBSD and Android

FreeBSD and Android run the instruction sets that already have backends. FreeBSD maps memory writable and executable by default, so its gate opens with its stack query, `pthread_attr_get_np`, in `stackBounds`. Zig treats Android as Linux with the Android ABI, so it takes the Linux gate and the `pthread_getattr_np` of bionic as they are. The x86-64 FreeBSD build compiles. The nightly workflow cross-builds it on a Linux runner and runs the conformance suite in a FreeBSD virtual machine there, through `cross-platform-actions/action`, in the default mode, `eager`, and `opt-eager`. Android is cross-built, and checked on an emulator image when one is available to a runner.

iOS and the game consoles refuse executable memory to ordinary programs, so the only native code they can run is code compiled ahead of time.

## Testing each target

`tools/test-linux.sh --riscv64 --loong64 --ppc64le` runs the gates of those three targets. Every Linux target is gated locally by a static musl build under qemu-user in the lima VM "boring", with the conformance suite under `LUS_JIT` set to `off`, the default, `eager`, `baseline`, and `opt-eager`, and with a `-Dgc-stress=97 -Dgc-verify=true` build under `eager` and `opt-eager`. CI cross-builds every target on every pull request. A nightly Linux job runs the same suite under `qemu-user-static` for each of them. The encodings of each assembler get byte-level unit tests against the output of a system assembler, as `a64.zig` and `x64.zig` have.

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

qemu-user reports a stack for the main thread that includes memory below it, which made chains of direct calls overrun the stack in the x86-64 gate. `stackBounds` keeps its low bound within `RLIMIT_STACK` below the top of the stack, so the qemu gates run direct calls as native systems do. The emulated gates set `LUS_EMULATED`, which skips `a_slow_reader_loses_its_connection_test` in `serve_test.lus`, the one test whose bound qemu-user breaks by buffering sockets differently. qemu does not model the memory ordering or the instruction fetch of real hardware, so each qemu target is confirmed on native hardware, such as a cloud server, before it is announced.

The interpreters of riscv64, ppc64le, and loong64 build from the same sources and pass the conformance suite under qemu-user in the VM, so a failure in the gate of a new JIT on those targets points at the new tier. Both tiers on riscv64 pass the whole suite under qemu-user in every JIT mode, with `LUS_JIT_DIRECT=1024`, and in a `-Dgc-stress=97 -Dgc-verify=true` build.

## Ahead-of-time compilation

Ahead-of-time compilation follows the platforms and has its own note, `aot.md`. Two facts from the platform work feed it. Native code embeds the absolute addresses of runtime routines, constants, and inline cache entries, so code compiled ahead of time needs relocations that the startup of the program resolves. The unwind tables of Windows and the constant pools of the new assemblers make the emitter produce a code object with metadata next to its bytes. An executable compiled ahead of time stores that object together with its relocations.
