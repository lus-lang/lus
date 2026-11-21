# Platforms

Lus 2.0 compiles hot functions to machine code on aarch64 and x86-64 under macOS and Linux, and to WebAssembly modules in the WebAssembly build (`jit.md`, `opt.md`, `wasmjit.md`). Every other target runs the interpreter, which is the same code with the JIT compiled out. Windows on x86-64 and on arm64 ships in every release and runs interpreted. We add targets in this order: Windows on x86-64, Windows on arm64, riscv64 under Linux, and then 32-bit ARM as an interpreter build. Each target has a gate that runs the whole conformance suite in every JIT mode on that target, natively or under emulation, before it merges.

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

## riscv64

riscv64 needs a third assembler, `jit/rv64.zig`, behind the interface that `a64.zig` and `x64.zig` share. The interface fits the instruction set. Comparisons are fused with their branches (`jumpIf`, `jumpIfImm`), which is the shape of the RISC-V branch instructions. Constants already go through a pool (`flushPool`). The target is RV64GC, the instruction set of every Linux distribution for riscv64. The Zba and Zbb extensions shorten address arithmetic and are used when the kernel reports them through `riscv_hwprobe`.

Three properties of the instruction set need work beyond the encodings.

- **Branch range.** A conditional branch reaches 4 KB in either direction, against 1 MB on aarch64. A conditional branch to a label that is not yet bound, or out of reach, is emitted as the inverted branch over a `jal`, which reaches 1 MB. Branches inside a short loop keep the short form. The interval at which out-of-line code and constants are emitted shrinks to match.
- **Constants.** A 64-bit constant takes up to eight instructions to build. Addresses of runtime routines and of objects load from the pool with `auipc` and `ld`.
- **Instruction fetch.** `fence.i` makes new code visible to the hart that runs it alone. Installing code calls the `riscv_flush_icache` system call, which reaches every hart that runs the process.

The optimizing tier follows the baseline tier as a second step, with register pools that RV64 makes larger than those of aarch64.

### Testing riscv64

The interpreter already passes on riscv64 (see the next section), so a failure in the gate of the JIT points at the new tier. The local gate runs a static `riscv64-linux-musl` build under `qemu-riscv64` in the lima VM "boring", with the conformance suite in every JIT mode and in a `-Dgc-stress=97 -Dgc-verify=true` build. The known qemu-user artifacts of the x86-64 gate apply, so chains of direct calls run with `LUS_JIT_DIRECT=off` there until `stackBounds` stops trusting the stack size that qemu reports. CI adds a nightly Linux job that runs the same suite under `qemu-user-static`. Every pull request cross-builds the target. The encodings get byte-level unit tests against the output of an assembler, as `a64.zig` and `x64.zig` have. Native hardware, such as a cloud RISC-V server, confirms the result before the target is announced, because qemu does not model the memory ordering or the instruction fetch of real harts.

## 32-bit ARM

The verdict is an interpreter build with no JIT.

A JIT for 32-bit ARM would hold every payload in a pair of registers. Each 64-bit load, store, add, and compare of the assembler interface becomes two or more instructions. Integer comparisons become two branches. The optimizing tier would have about six register pairs to allocate. The value layout itself fits, since the WebAssembly build runs it on a 32-bit target, but both tiers would need a second code path for every template, which is the cost JavaScriptCore pays for its 32-bit value representation. The hosts that run 32-bit ARM today are older Raspberry Pi systems, older Android devices, and embedded boards. They get the interpreter.

The interpreter does not build for `arm-linux-musleabihf` yet. The parallel marker of the collector updates its mark bitmap with 64-bit atomic operations (`isMarkedSmallAtomic` and `setMarkSmallAtomic` in `vm/heap.zig`), which 32-bit ARM lacks. The WebAssembly build is single-threaded and never compiles them. Mark words of the native word size fix it. The work is that change and an `arm-linux-musleabihf` release artifact, gated by the conformance suite under `qemu-arm` in the lima VM and in the nightly qemu job.

## ppc64le, s390x, and loong64

None of these targets gets a JIT unless a user asks.

Static interpreter builds for `riscv64-linux-musl`, `powerpc64le-linux-musl`, and `loongarch64-linux-musl` build from the same sources and pass the conformance suite under qemu-user in the lima VM, 6325 tests each. The one failure in each run is `a_slow_reader_loses_its_connection_test` in `serve_test.lus`, the known artifact of emulated socket buffers that the x86-64 gate shares.

- **ppc64le** has JIT ports in V8 and HotSpot because IBM maintains them. The interpreter builds for `powerpc64le-linux-musl` unchanged, so supporting it costs a release artifact and a qemu job.
- **s390x** is big-endian. `Value.make`, every reader of a value by its two words, and the word of frame flags assume the little-endian layout. The build stops at the assertion in `vm/state.zig`. Even the interpreter needs an audit of the byte order first, so we leave the target unsupported.
- **loong64** is little-endian and 64-bit, with fixed-width instructions and compare-and-branch instructions like RISC-V. A loong64 backend would cost about what the riscv64 assembler costs, with longer branch ranges. The interpreter builds for `loongarch64-linux-musl` unchanged. A release artifact comes first if users appear.

## Other systems

FreeBSD and Android run the same instruction sets as the supported targets. They need the gate opened, the stack query of their system in `stackBounds`, and a CI runner. The executable memory path of Linux works on both. iOS and the game consoles refuse executable memory to ordinary programs, so the only native code they can run is code compiled ahead of time.

## Ahead-of-time compilation

Ahead-of-time compilation follows the platforms and has its own note, `aot.md`. Two facts from the platform work feed it. Native code embeds the absolute addresses of runtime routines, constants, and inline cache entries, so code compiled ahead of time needs relocations that the startup of the program resolves. The unwind tables of Windows and the constant pools of riscv64 make the emitter produce a code object with metadata next to its bytes. An executable compiled ahead of time stores that object together with its relocations.
