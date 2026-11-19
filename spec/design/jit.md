# The baseline JIT

Lus 2.0 compiles hot functions to native code on aarch64 and x86-64. The compiler is a baseline tier: it translates one function at a time, one instruction at a time, in a single pass, and it keeps the interpreter's data layout. Native code is semantically identical to the interpreter. This note describes how the two tiers share one definition of every opcode, how frames move between them, what runs inline, and what the tier costs and gains.

## One definition per opcode

The interpreter is one function, `run` in `vm/interp.zig`, whose dispatch loop is a labelled switch. Zig instantiates it at compile time in several modes.

- `fast` is the plain loop.
- `hooked` fires debug hooks before every instruction.
- `warm` is the plain loop plus the tier-up counters. A state whose JIT is on runs it.
- `step` runs the body of one opcode and returns. There is one such instantiation per opcode.

In `step` mode the switch operand is known at compile time, so the compiler keeps only the body of that opcode, and the fetch at the end of the body becomes a return that reports where execution continues. The result is about ninety small routines, 35 KB in total, each of which is the interpreter's own code for one opcode. They are the step routines in `jit/helpers.zig`.

Native code is built on those routines. For every instruction the emitter writes either a call to the step routine of its opcode, or an inline fast path that ends in the same call for every case it does not handle. A guard that fails never guesses: it runs the instruction again from the start in the step routine. The interpreter therefore decides every metamethod, every coercion, every error message, and every yield, and a new opcode works in native code as soon as the interpreter implements it.

A step returns one of a few codes. `next` continues with the following instruction. `skip` continues after it, which is how a test instruction reports that its jump does not run. `dispatch` means the pc or the frame changed, and native code then asks `jit.dispatch` for the code of the top frame. The remaining codes leave native code: the frame count dropped to the stop depth, an error was raised, a coroutine yielded, or the interpreter must take over.

### The choice of a template emitter

The plan for 2.0 names copy-and-patch, with stencils cut from compiled object code. The intent behind it is that the tiers cannot diverge and that the JIT costs little code. Three properties of the current toolchain make a template emitter the better way to reach that intent in Zig 0.17.1.

- Stencils need a calling convention that pins the interpreter state in registers across tail calls on both architectures, and relocations that a build step can find and patch. Extracting them means parsing Mach-O and ELF objects for two architectures at build time and rewriting address materialization sequences on aarch64. That is a second linker.
- Comptime already gives the property that matters. The step routines are the interpreter bodies, instantiated by the compiler, so the shared definition needs no object-file processing.
- The fast paths that pay off are short. They are written once against a small assembler interface that `jit/a64.zig` and `jit/x64.zig` both implement, so each template exists once for both architectures.

The cost of this choice is that the inline fast paths are written by hand and must agree with the interpreter. They are kept small, each one falls back to the step routine, and `tests/conformance/jit_test.lus` and the unit tests in `jit/tests.zig` compare them with the interpreter at their edges.

## Frames belong to both tiers

Native code keeps no Lus value in a machine register across instructions. Registers stay in the Lus stack, frames stay in the frame list of the thread, and the stack top follows the interpreter's rules. Calls between Lus functions never recurse on the native stack in either tier.

It follows that every instruction boundary is both an exit and an entry. Leaving native code is a return with a status. Entering it is a jump to the code of an instruction, whose address comes from a table with one offset per instruction. On-stack replacement at a loop header is that same jump. The collector, tracebacks, `debug.getinfo`, coroutines, and exception tables read the same frames whatever tier is running.

Native code pins four values in callee-saved registers: the thread, the address of register 0 of the running frame, the index of that register in the stack, and the stop depth. Anything that may move the stack is followed by a reload of the register address. Each block of code starts with an entry sequence that the runtime calls as a C function. It saves the pinned registers once, and every function compiled for the same state jumps in and out of other blocks under that one native frame.

### What happens to each kind of control flow

- **Errors.** A step that raises returns `failed` with the pc saved as the interpreter saves it. `execute` finds the handler in the exception table, as it does for interpreted frames, and native code continues at the handler when the function has some.
- **Metamethods.** A Lus metamethod runs as a frame. The step that pushed it returns `dispatch`, the metamethod runs in whichever tier has it, and its return applies the finish action and dispatches into the caller.
- **Yields.** A yield unwinds to `resume` through the status code. The resumed coroutine enters native code again at the saved pc.
- **Hooks.** Native code never runs while a hook is set. `execute` picks the hooked loop whenever the hook mask is nonzero, and a step that returns from a native that set a hook reports it, as the interpreter's own check does. `lus debug` sets its mask on every thread, so a debugged program is interpreted.
- **Finalizers.** Backward jumps and calls test the pending finalizer count inline and take the step routine when it is nonzero.

## Tier-up

A function has a counter that starts at the threshold, 60 events by default. The events are calls, loop iterations, and numeric loops about to start.

- Native code counts a call exactly when it reaches a function that has no code yet, and so does a call from a native function.
- The `warm` interpreter loop samples. Calls and backward jumps decrement a budget held in a machine register. When it reaches zero, the running function is charged for the whole period, and the next period gets a different length between 5 and 12, so a regular program cannot hide a function from the samples.
- A numeric `for` or `range` loop of 16 or more iterations charges its function for the whole count when it starts. A long loop therefore compiles before its first iteration, and its loop instruction counts nothing.

A function that reaches zero is compiled at once. The interpreter then leaves its loop with the frame at an instruction boundary, and native code picks it up there. This covers the program that is one long top-level loop.

Counting in memory at every call and loop iteration cost the interpreter up to 17 percent, and any counting in the plain loop changed its register allocation enough to cost several percent. That is why the counters live in a separate instantiation: a state whose JIT is off runs the `fast` loop, which is the same code as a build without the JIT.

Functions with more than 30 000 instructions stay in the interpreter, and so does a function whose code would put a branch out of range.

## What runs inline

| Instructions | Native code |
|---|---|
| `move`, `loadk`, `loadi`, `loadf`, `loadnil`, `loadtrue`, `loadfalse` | Inline. Constants are immediate operands. |
| `getupval`, `setupval` | Inline, with the barrier bit tested inline and its slow part called. |
| `add`, `sub`, `mul` and their constant forms, `addi` | Integer operands inline with wrapping results, float operands out of line, anything else in the step routine. A float constant makes the float case the inline one. |
| `div`, `divk` | Float operands inline, two integers converted out of line. |
| `mod`, `idiv` and their constant forms | Integers inline with the rounding of `ops.imod` and `ops.idiv`. A divisor of zero or minus one takes the step routine. |
| `band`, `bor`, `bxor`, `unm`, `not` | Integers inline (any value for `not`). |
| `eq`, `lt`, `le`, `lti`, `lei`, `gti`, `gei`, `eqk`, `test`, `testset`, `testnil` | Integers inline and fused with the jump that follows. Floats out of line for the ordered comparisons. `eqk` handles integer, nil, boolean, and interned string constants. |
| `jmp` | A direct branch. A backward jump first tests for pending finalizers. |
| `forloop`, `tforloop` | The integer loop and the generic loop test inline. Float and exact loops take the step routine. |
| `call` | A callee with native code and fixed parameters is entered in native code: the call pushes the interpreter's frame from a prepared image, clears the callee's registers, and jumps. A native function is called through a helper that mirrors the interpreter. |
| `ret0`, `ret1` | A frame pushed by a native call returns in native code when nothing needs closing, to the address its caller left in the frame. |
| `tailcall` | A helper that mirrors the interpreter for a compiled callee with fixed parameters. |
| `getfield`, `setfield`, `gettabup`, `settabup`, `self`, `gettable`, `settable`, `getindex`, `len` | A call to the fast path the interpreter runs inline (`interp.fast`), then the step routine. |
| Everything else | The step routine. |

Table accesses are calls on purpose. The inline caches and the array kinds are defined in one place, `interp.fast` and `vm/table.zig`, and native code knows nothing about the layout of a table.

The emitter writes a value as its two 64-bit words and copies it as two words. A value is often written just before it is copied, for example a result that is returned at once, and a 16-byte load would wait for both stores to leave the store buffer. Fresh registers of a callee are cleared with one 16-byte store each. These two rules were worth a quarter of the time of a call.

## Executable memory

Each state owns an arena (`jit/mem.zig`) of 1 MB chunks. A block is carved out of a chunk for each function, the bookkeeping lives outside the chunks, and a chunk with no blocks left returns to the system. The collector frees the block of a function when it frees the function, and closing the state unmaps every chunk. A worker has its own state, so it has its own arena and its own code.

On Apple Silicon the chunks are mapped with `MAP_JIT`, and the thread switches to write mode only while a finished function is copied in. Elsewhere the chunks are mapped readable, writable, and executable. A system that refuses such a mapping turns the JIT off for that state, and the program runs interpreted.

Code is position independent. Addresses of runtime routines and of constants are absolute, which is safe because the collector never moves an object and a function keeps its constants alive for as long as its code exists.

## Controls

- `zig build -Djit=false` builds without the JIT. The WebAssembly build and every target other than aarch64 and x86-64 on macOS and Linux have none.
- `LUS_JIT=off` interprets everything. `LUS_JIT=eager` compiles every function on its first call, which is what the test suites use. `LUS_JIT=on` is the default.
- `LUS_JIT_THRESHOLD=N` sets the number of events before a function compiles.
- `debug.jit()` returns the setting, and `debug.jit(f)` tells whether `f` has native code.
- A binary chunk written by `lus compile --profile` or `lus build --profile` names the functions that were hot in a profiling run, and loading it compiles them at once (`warmstart.md`).
- A host written in Zig calls `jit.configure`.

## Measurements

Wall times in seconds, best of five runs, ReleaseFast on an Apple silicon Mac. "before" is the interpreter of the same tree, built with `-Djit=false`. "off" is the JIT build with `LUS_JIT=off`. `luajit -joff` is LuaJIT 2.1 with its JIT disabled, and `luajit` is LuaJIT with its tracing JIT.

| benchmark | before | off | JIT | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.245 | 0.246 | 0.214 | 0.248 | 0.039 |
| closures | 0.089 | 0.092 | 0.078 | 0.134 | 0.126 |
| data | 0.034 | 0.035 | 0.034 | 0.277 | 0.051 |
| fib | 0.059 | 0.060 | 0.034 | 0.036 | 0.010 |
| gcpause | 0.401 | 0.402 | 0.401 | 0.448 | 0.410 |
| interp | 1.051 | 1.063 | 1.056 | 2.003 | 1.275 |
| loop | 0.233 | 0.235 | 0.145 | 0.249 | 0.092 |
| methods | 0.282 | 0.285 | 0.300 | 0.244 | 0.007 |
| patterns | 0.207 | 0.211 | 0.211 | 0.263 | 0.258 |
| strings | 0.178 | 0.179 | 0.181 | 0.250 | 0.207 |
| tables | 0.189 | 0.190 | 0.196 | 0.163 | 0.132 |
| unicode | 0.091 | 0.096 | 0.100 | 0.033 | 0.005 |

Code that spends its time in bytecode gains the most. `loop` runs 1.6 times faster and `fib` 1.7 times, `closures` gains 12 percent, and `arrays` gains 13 percent from the inline arithmetic around its table calls. `loop` is now well ahead of LuaJIT's interpreter, and `fib` is level with it, where the interpreter took 1.6 times as long. The benchmarks that live in the runtime (`data`, `gcpause`, `interp`, `patterns`, `strings`) are unchanged, as expected.

`methods`, `tables`, and `unicode` are slower in native code than interpreted, by 6, 4, and up to 10 percent. They are dominated by table accesses, allocation, and calls to native functions, which native code makes through the same routines as the interpreter with a call in place of a dispatch. A call costs a little more than the dispatch it replaces, most of all for a table constructor and for a store that adds a key. Those three rows stay behind LuaJIT's interpreter, as they did before the JIT, for reasons that lie in the runtime.

The "off" column shows that the interpreter of a JIT build keeps its speed. The differences from "before" are within the noise of the measurement, which is a few percent on the short rows.

LuaJIT's tracing JIT remains several times faster on `fib`, `methods`, `arrays`, and `unicode`. Closing that distance takes what a baseline tier leaves out by design: values kept in machine registers across instructions, inline caches compiled into the code, and type feedback. The frame protocol is the largest fixed cost today. A call and return between two compiled functions is about 90 machine instructions and 25 stores, because it builds the interpreter's full frame.

The numbers of the `rewrite` branch when this work started, before the array element kinds merged into it, were 0.106 for `closures`, 0.065 for `fib`, 0.255 for `loop`, 0.398 for `methods`, 0.215 for `tables`, and 0.108 for `unicode`.

## Open ends

- Table accesses inline. Once shapes or the element kinds settle, a guarded inline load can replace the helper call, and the helpers stay as the fallback. This is what turns the three slower rows above into gains.
- A leaner frame for calls between compiled functions.
- Windows. The emitter follows the System V convention on x86-64, and the arena uses `mmap`.
- Systems that forbid writable and executable mappings run interpreted. Mapping the code twice, once writable and once executable, would lift that.
- The embedding interface in C has no JIT control yet. A state created through it uses the default setting, and a host written in Zig calls `jit.configure`.
