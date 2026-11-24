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

| target | interpreter | baseline tier | optimizing tier | ahead of time | release artifact |
|---|---|---|---|---|---|
| aarch64 macOS | yes | yes | yes | yes | yes |
| x86-64 macOS | yes | yes | yes | yes | yes |
| aarch64 Linux | yes | yes | yes | yes | yes, static musl |
| riscv64 Linux | yes | yes | yes | yes | not yet |
| loong64 Linux | yes | yes | yes | yes | not yet |
| ppc64le Linux | yes | yes | yes | yes | not yet |
| x86-64 Linux | yes | yes | yes | yes | yes, static musl |
| x86-64 Windows | yes |  |  |  | yes |
| arm64 Windows | yes |  |  |  | yes |
| 32-bit ARM Linux | yes | yes | yes | yes | not yet |
| s390x Linux | yes | yes | yes | yes | not yet |
| FreeBSD (aarch64, x86-64) | yes | yes | yes | yes | not yet |
| wasm32 WASI | yes | WebAssembly modules |  |  | the npm package |

The column "ahead of time" marks the targets whose assembler records relocations, so that `LUS_JIT_AOT` and `lus build --aot` work there (`aot.md`).

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

32-bit ARM has both tiers for ARMv7-A with VFPv3-D16, the target of every hard-float distribution. The value layout fits as it is, with a 64-bit payload and a tag word, since the WebAssembly build already runs it on a 32-bit target. The design keeps the second code path inside the assembler.

### Work before the JIT

The interpreter builds for `arm-linux-musleabihf` and passes the conformance suite under `qemu-arm` in the VM. Two places used 64-bit atomic operations, which 32-bit ARM lacks. The parallel marker of the collector updates its mark bitmap, whose words stay 64 bits wide for the sweep, through the 32-bit half of the word that holds the bit (`markWord` in `vm/heap.zig`). The sequence counter of the debug adapter is a word-sized atomic. `tools/test-linux.sh --arm` runs the gate.

### Pairs inside the assembler

Every register of the interface holds 64 bits inside `jit/a32.zig`, as a low word and a high word. Each operation of the interface keeps its 64-bit meaning, so an addition is `adds` and `adc`, a multiplication is `umull` and two cross products, and a compare-and-branch compares the high words and then, when they are equal, the low words. A signed comparison subtracts both words and branches on the sign of the difference. The templates and the code generator therefore keep one code path for every target.

The one distinction they gain is the width of a word in memory. A pointer, a count, or a stack index is 4 bytes on a 32-bit target, and a payload or a 64-bit counter is 8. The interface gains `loadWord` and `storeWord`, which are `load64` and `store64` on a 64-bit target. Every site that loads or stores a pointer-sized field names them. A word loaded into a register clears its high half. A payload that holds a pointer keeps its high word zero, which is what `Value.make` writes, so a pointer read from a payload is its low word. An address that `lea`, `addScaled`, or `subScaled` computes is a low word with a zero high word.

Arithmetic on such words has operations of its own. `addWord`, `subWord`, and `addImmWord` compute a stack index or a count. They are `add`, `sub`, and `addImm` on a 64-bit target. On this target each is one instruction that leaves a zero high word in the record of the assembler ("High words"). The call entry, the tail entry, the return, and the loop counter of the baseline templates use them, which took the instructions that the baseline code of `closures.lus` executes for 40000 iterations from 26.8 to 25.8 million.

### Registers

32-bit ARM has thirteen general registers besides the stack pointer, the link register, and the program counter. The assembler places each word of each register of the interface in a machine register, in the native frame that the entry sequence opens, which `r11` points at, or on the native stack.

| register of the interface | low word | high word |
|---|---|---|
| the thread, the address of register 0 | `r4`, `r5` | reads as zero |
| the index of register 0, the stop depth | a word of the frame | reads as zero |
| `t0`, `t1`, `t2` | `r6`, `r3`, `r2` | `r7`, `r8`, `r9` |
| `t3`, `t4` | `r1`, `r0` | a word of the frame |
| the first scratch register of the code generator | `r10` | a word of the frame |
| `t5`, `t6`, the second scratch register of the code generator, six more pool registers | a word of the frame | a word of the frame |
| a spilled value of the optimizing tier | a word of the native stack | the word after it |

The scratch registers of the assembler are `r12` and the link register. A word that lives in the frame or on the stack moves through one of them: an operation loads it, computes, and stores the result. A multiplication or a division whose low words live in memory needs a third scratch register, so it saves `r4` on the stack while it runs. Code that uses `t0` to `t2` runs at the speed of register pairs. The optimizing tier allocates thirteen registers, `t0` to `t6` and the six frame registers, lowest first, so the values of a small loop live in the three pairs.

Four other placements were built and measured by the instructions that the benchmarks execute. Two of them move the high words of `t1` and `t2` to the frame, which frees `r8` and `r9` for the low words of `t5` and `t6`, or of the second scratch register and `t5`. Both ran more instructions on every benchmark. The baseline code of `loop.lus` then executes 25.7 million instructions for 300000 iterations where it executes 21.8 million, and `arrays.lus` executes 55 million in the default mode where it executes 48.5 million, since integers fill the pairs. The other two move the thread to the frame, which frees `r4` for the low word of `t5` or of the second scratch register. They moved each benchmark by a few percent, in both directions. With `t5` in `r4`, the baseline code of `arrays.lus` executes 153 million instructions where it executes 159 million, and the baseline code of `fib(24)` executes 27.9 million where it executes 26.1 million, because the call paths read the thread often.

A spilled value is an operand where it lies. `spillReg` names a word of the native stack as a register of the interface. The code generator passes that name where another target loads the value into a scratch register first. The assembler reads and writes the two words in place. An operation that moves the stack pointer while it runs, such as the call of a division routine, adds the bytes it pushed to the offsets. In `fib.lus`, whose every call keeps its argument and a partial sum on the stack, this took the instructions that native code executes for `fib(24)` from 8.65 to 7.15 million.

Floats use the double registers of VFPv3-D16 directly. The optimizing tier allocates `d0` to `d7`, the code generator keeps `d8` and `d9` as scratch registers, the assembler keeps `d10` and `d11`, and `d12` to `d14` hold constants. The entry sequence saves `d8` to `d14` with the general registers that belong to its caller.

### High words

Most registers hold a pointer, a count, a tag, or a stack index, whose high word is zero. While the assembler emits straight-line code it records which high words it knows to be zero. A load of a word or a byte, an address, a constant below 2^32, the result of `call`, and a bitwise operation on such registers each set the record. An operation that reads a recorded register works on one word. A comparison of two such registers is one `cmp` with an unsigned condition. A test against zero reads the low word.

A recorded high word that lives in the frame stays unwritten at first. The assembler writes the pending zeros where a path that never passed the record can reach the code: at a label, before an unconditional jump, a local call, or a return, and at `offset`, which marks a point that code enters from elsewhere. A conditional branch writes them between its comparison and its branch, with a `mov` and stores that keep the flags. A conditional branch to out-of-line code, whose label comes from `newColdLabel`, goes through a *ramp*: a few instructions after the rest of the code that write the zeros and jump on. The path that falls through such a branch pays nothing, which matters because it is the hot path of every guard and of every template. The record is empty after a label.

`dead` tells the assembler that a register holds no value that later code reads, which drops its pending zero. The templates call it for the temporaries at every instruction boundary. The code generator calls it for its scratch registers before every instruction of the intermediate representation.

The stub of a barrier of the optimizing tier calls the runtime and keeps every pool register. On another target it saves them all. Here most of their words survive the call, in the frame or in machine registers that belong to the caller. `saveVolatile` saves what the call and its five arguments overwrite: `r0` to `r3`, `r8` and `r9`, four words of the frame, and `d0` to `d7`. The loop of `tables.lus` that fills an array with new tables takes the barrier on nine stores of ten. For 100000 elements native code executes 38.4 million instructions where it executed 46.5 million.

Only out-of-line code is reached through a ramp because of what a far jump costs under `qemu-arm`. The emulator chains translated blocks inside one 4 KB page, so a branch to another page costs about as much as ten instructions. A build that sent every conditional branch through a ramp ran `methods.lus` in 207 ms against 146 ms before the record existed, while it executed fewer instructions, because the branch that closes the loop left through a ramp on another page.

### Constants and words in memory

The entry sequence loads three float registers with the 64-bit words that native code stores most: zero in `d12`, the tag word of an integer in `d13`, and the tag word of a float in `d14`. `storeImm64` of one of them is one `vstr`, where two words built in a scratch register take four instructions. `emit.zig` asserts that the two tag words are the ones the layout of a value defines.

The code generator finds four operations with `@hasDecl` that only this assembler has, where a 64-bit target loads a scratch register. `jumpIfWide` compares a register with a 64-bit integer one word at a time, so the guard of an array read against the bits of the absent marker takes five instructions. `floorDivImm` divides by a constant. `addMemImm` and `jumpIfMems` count the bytes of sunk allocations and compare them with their limit where the two words lie. The second scratch register of the code generator lives in the frame, so each of these operations saves the stores and loads of a 64-bit temporary.

### Calls

The temporaries share their low words with the argument registers of AAPCS in the order of s390x: `t4` is the first argument and the first result, `t3` the second of each, `t2` the third argument, `t1` the fourth, and `t5` the fifth. The interface has four kinds of call.

- **`call`** calls a routine that takes up to four words (see "Order"). Their low words are in `r0` to `r3` already. The result is `r0`, whose register of the interface gets a zero high word in the record of the assembler.
- **`call5`** calls a routine that takes five words. The low word of the fifth travels on the stack. On every other target it is `call`.
- **`callWide`** calls a routine whose arguments and result are all 64-bit integers: the helpers of an array access and every routine that a `callc` instruction of the optimizing tier reaches. The first argument travels in `r0` and `r1`, the second in `r2` and `r3`, and the third and fourth on the stack. The result comes back in `r0` and `r1`.
- **`callPair`** calls a routine that returns `jit.Target`, which AAPCS returns through memory. The assembler passes the address of two words of the frame in `r0`, moves the four word arguments up by one, the last of them onto the stack, and loads the two words into the result registers afterwards.

The stack pointer is a multiple of eight at every call. The entry sequence leaves it so, the code generator moves it by multiples of sixteen, and the arguments on the stack take eight or sixteen bytes.

A local call, which enters a call entry or a direct entry of optimized code, stores its return address in a word of the frame. The routine it calls reads the address from there whatever it ran in between, which frees the link register as a scratch register. `saveLink` copies the word into the native frame of an activation, where `opt.unwind` finds it as it does on every target.

### Division and conversions

ARMv7-A makes the division of 32-bit integers optional. The kernel reports it in the hardware capabilities of the process. On a processor that divides, `divRem` and `floorDiv` first test that both operands are signed 32-bit integers, which holds when the high word equals the sign of the low word. They then divide in place with `sdiv` and find the remainder with `mls`. Two conditional instructions turn the truncated results into the floor of the quotient and the remainder with the sign of the divisor. A constant divisor of 32 bits needs no test of its own.

Every other division calls a routine in `a32.zig` that divides in Zig. So does all code compiled ahead of time, which may run on a processor that has no `sdiv`. An operation of the interface keeps every register it does not name, so the call of a routine saves `r0` to `r3` and `d0` to `d7` around itself. It reads an operand that lives in one of them from where it was saved. It writes a result that lives in one of them to the same place, so that the restore loads it. `floatToInt` calls a routine the same way.

VFP converts only 32-bit integers. `intToFloat` converts the low word as an unsigned integer and the high word as a signed one, and adds the low float to the high float times 2^32 with `vmla`. Both the product and the low float are exact, so the one addition rounds as a direct conversion of the 64-bit integer does.

The statistics of the table library convert arrays of integers in the runtime, where the compiler calls `__aeabi_l2d` for each 64-bit integer. On this target `lib/table.zig` computes the same two-word sum as `intToFloat`. `data.lus` spent 36 percent of its instructions in that routine. For 20000 elements it now executes 40.7 million instructions where it executed 76.2 million.

### Encoding and memory

The assembler emits the A32 encoding, whose branches reach 32 MB, so every branch is one instruction and the assembler keeps no pool. A constant builds in place with `mov`, `mvn`, or `movw` and `movt`. An offset that a load or a store cannot hold is added to the base in a scratch register first. New code becomes visible to instruction fetch through the `cacheflush` system call of ARM Linux.

A frame of a 32-bit target is padded to 64 bytes, so that native code finds a frame with a shift and an add on every target.

The C library of a static build finds the stack of the main thread by probing the pages below it with one system call each. Under qemu-user that walk covers the gigabyte of address space that the emulator reserves for a 32-bit program, which takes seconds. `stackBounds` therefore answers with zeros for the main thread of a static 32-bit ARM build, which gives a chain of direct calls there the 160 KB below its entry. Every other thread asks the C library, which answers from its own record of the thread.

### Code compiled ahead of time

`LUS_JIT_AOT` and `lus build --aot` work on 32-bit ARM as they do on the 64-bit targets (`aot.md`). On a 64-bit target the value of a constant tells whether it can be an address, since the heap and the code lie above 4 GB. On 32-bit ARM an address is one word, so the interface says which constants can be addresses, and the emitters name the integers among them.

- **Constants the size of a pointer.** `movImm`, `storeImm64`, `storeImmWord`, and every kind of call take a constant that may be an address. Ahead of time the assembler hands the resolver each of them whose high word is zero and whose low word is at least 64 KB, where the image, the heap, and the code of a process begin. The resolver names the address, calls the value a literal, or calls it unknown, as on every target. The instruction counts, slot numbers, and tags that the emitters write lie below 64 KB and build in place.
- **32-bit integers.** The constants of `addImm`, `jumpIfImm`, and `storeImm32` are 32-bit integers on every target and build in place. A guard or a branch of the optimizing tier whose constant is an address carries the flag `address`. Ahead of time such a constant loads into a register through `movImm`, and the comparison takes two registers.
- **Integers the size of a pointer.** The baseline templates and the code generator pass an instruction word, a hash, an integer or float constant of the program, and the shaped bit of a table through `movImmReloc` with the `literal` name, or through `storeLiteral`. Those values never reach the resolver. In the intermediate representation `kint` holds only integers, and every constant address is a `kptr`.

An address takes the form `movw` and `movt`, whose two 16-bit fields the loader patches (`reloc.Form.arm_pair`). The high word of the register pair that holds an address is zero in every process, so it builds in place. The division and truncation routines of `a32.zig` take the routine numbers after the step routines.

The executable of 32-bit ARM is static and loads at 64 KB. An integer that reaches the resolver without a `literal` name and lands in the image, the heap, or the executable memory is unknown, so its function or unit stays out of the code section (`aot.md`, "Testing"). The linker of `lus build` writes x86-64 and aarch64 executables, so `lus build --aot` on 32-bit ARM appends the code section to the prebuilt runtime, which relocates it at load.

Under `qemu-arm`, the executable that `lus build --aot` makes of `tests/build/aot.lus` on `lus-runtime` prints the output of `zig build test-runtime`, and `LUS_AOT_REPORT` counts 9 functions and 6 units installed and both loop units entered. The benchmarks `fib`, `loop`, `methods`, `arrays`, `tables`, `closures`, `strings`, `data`, `unicode`, and `patterns` give the same output compiled ahead of time, bundled on `lus-runtime`, and bundled on `lus`. `fib` takes 0.18 s compiled ahead of time against 0.88 s interpreted on `lus-runtime` and 0.21 s under the JIT, and `methods` takes 0.16 s against 5.40 s and 0.14 s, in ReleaseSafe builds under `qemu-arm` on an Apple silicon Mac.

### Measurements

The table gives the time of each benchmark of `tests/bench` in milliseconds before and after the changes that this section describes: the record of high words, `call5`, `dead`, the constants in float registers, the words of the stack as registers, the check of the chain limit, the division in place, the wide constants, and the counter of sunk allocations. Each time is the best of 3 runs under `qemu-arm` in the VM, with the two builds interleaved, in ReleaseSafe on an Apple silicon Mac.

| benchmark | off, before | off, after | baseline, before | baseline, after | default, before | default, after |
|---|---|---|---|---|---|---|
| `fib` | 813 | 811 | 383 | 361 | 213 | 159 |
| `loop` | 20317 | 20929 | 13990 | 1767 | 13550 | 827 |
| `arrays` | 5951 | 5901 | 2910 | 2604 | 1129 | 681 |
| `closures` | 1735 | 1709 | 1412 | 1383 | 1545 | 1375 |
| `methods` | 4903 | 5070 | 3850 | 3683 | 148 | 187 |
| `tables` | 2081 | 2043 | 1815 | 1650 | 1692 | 1573 |
| `strings` | 2007 | 1967 | 2094 | 1970 | 2128 | 2041 |
| `data` | 1889 | 1890 | 1823 | 1721 | 1717 | 1610 |

The translation log of qemu counts the instructions that native code executes, and the count stays the same under any load on the VM. In the default mode the count went from 11.1 to 6.7 million for `fib(24)`, from 70.5 to 48.5 million for `arrays.lus` with 20000 elements, from 33.2 to 24.8 million for 40000 iterations of `closures.lus`, and from 18.0 to 13.7 million for 300000 iterations of `methods.lus`. `loop.lus`, whose body is one modulo, spent 66 of its 76 million instructions for 300000 iterations in the division routines of the runtime. It now executes 9.3 million in all.

`methods.lus` took longer in the default mode after these changes although its loop executed fewer instructions. The two halves of that loop lay 1.2 KB apart, on two 4 KB pages. `qemu-arm` chains translated blocks only inside one page, so every iteration looked up two blocks. The code generator now emits the blocks of a loop next to each other (`opt.md`, "One code generator"), which took the benchmark from 173 to 127 ms.

`closures.lus`, `tables.lus`, `strings.lus`, and `data.lus` spend most of their time in the runtime, so native code moves them little. After the changes native code executes 38 percent of the instructions of `closures.lus`, whose other instructions create closures, return through the step routine, and sweep. `data.lus` spends 36 percent of its instructions in the routine of the compiler runtime that converts a 64-bit integer to a float.

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

The interpreters of riscv64, ppc64le, and loong64 build from the same sources and pass the conformance suite under qemu-user in the VM, so a failure in the gate of a new JIT on those targets points at the new tier. Both tiers on riscv64 pass the whole suite under qemu-user in every JIT mode, with `LUS_JIT_DIRECT=1024`, and in a `-Dgc-stress=97 -Dgc-verify=true` build. Both tiers on 32-bit ARM pass it the same way under `qemu-arm`. The suite and the tests of the language server also pass there under `LUS_JIT_AOT=reload` with an empty log, in the default mode, `eager`, and `opt-eager`, and `tools/test-linux.sh --arm` runs the default mode of that check.

## Ahead-of-time compilation

Ahead-of-time compilation follows the platforms and has its own note, `aot.md`. Two facts from the platform work feed it. Native code embeds the absolute addresses of runtime routines, constants, and inline cache entries, so code compiled ahead of time needs relocations that the startup of the program resolves. The unwind tables of Windows and the constant pools of the new assemblers make the emitter produce a code object with metadata next to its bytes. An executable compiled ahead of time stores that object together with its relocations.
