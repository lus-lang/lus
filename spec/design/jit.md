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

The cost of this choice is that the inline fast paths are written by hand and must agree with the interpreter. Each one is the hit path of a fast path that the interpreter already has, each one falls back to the step routine, and `tests/conformance/jit_test.lus` and the unit tests in `jit/tests.zig` compare them with the interpreter at their edges.

## Frames belong to both tiers

Native code keeps no Lus value in a machine register across instructions. Registers stay in the Lus stack, frames stay in the frame list of the thread, and the stack top follows the interpreter's rules. Calls between Lus functions never recurse on the native stack in either tier.

It follows that every instruction boundary is both an exit and an entry. Leaving native code is a return with a status. Entering it is a jump to the code of an instruction, whose address comes from a table with one offset per instruction. On-stack replacement at a loop header is that same jump. The collector, tracebacks, `debug.getinfo`, coroutines, and exception tables read the same frames whatever tier is running.

A frame (`state.Frame`) has a fixed layout of 64 bytes, so native code writes one with a few stores and finds one with a shift and an add. Every frame is complete whichever tier pushed it. A frame that native code pushed carries the `lean` flag and the address in native code where its caller continues. A frame that the `call` instruction of the interpreter pushed carries the `plain` flag. Both flags say the same about a frame: its caller is a Lus frame of the same run, and its return is the plain one, which hands the results to that caller. A return tests for them with one load of the word that holds every flag.

Native code pins four values in callee-saved registers: the thread, the address of register 0 of the running frame, the index of that register in the stack, and the stop depth. Anything that may move the stack is followed by a reload of the register address. Each block of code starts with an entry sequence that the runtime calls as a C function. It saves the pinned registers once, and every function compiled for the same state jumps in and out of other blocks under that one native frame.

### What happens to each kind of control flow

- **Errors.** A step that raises returns `failed` with the pc saved as the interpreter saves it. `execute` finds the handler in the exception table, as it does for interpreted frames, and native code continues at the handler when the function has some.
- **Metamethods.** A Lus metamethod runs as a frame. The step that pushed it returns `dispatch`, the metamethod runs in whichever tier has it, and its return applies the finish action and dispatches into the caller.
- **Yields.** A yield unwinds to `resume` through the status code. The resumed coroutine enters native code again at the saved pc.
- **Hooks.** Native code never runs while a hook is set. `execute` picks the hooked loop whenever the hook mask is nonzero, and a step that returns from a native that set a hook reports it, as the interpreter's own check does. `lus debug` sets its mask on every thread, so a debugged program is interpreted.
- **Finalizers.** Backward jumps and calls test the pending finalizer count inline and take the step routine when it is nonzero.

### The call and the return of the interpreter

The interpreter makes a call between two Lus functions in the `call` instruction itself. It reads what the push needs once into locals, sets the parameters that the caller left out to nil, and writes the frame with five stores: the closure with a null native, the function slot with the base, the return slot with the wanted count, the saved pc, and the word of flags. The other registers of the callee keep what the stack holds, and `interp.md` says why that is sound and what else the call leaves out.

A function records whether one of its frames can own an open upvalue or a to-be-closed variable (`Proto.call.closes`). Only a closure that the function makes opens an upvalue on one of its registers, and only `tbc` and `tforprep` mark a variable to be closed. The call copies that into the frame as the `closes` flag. The return of a plain frame without it compares the flags word with one constant and closes nothing. Every other frame takes the tests for open upvalues and to-be-closed variables first.

The dispatch loop keeps three values of the running frame in locals: the frame, the code pointer, and the register pointer. The few instructions that need the index of register 0 read it from the frame. The constants and the inline caches of a function are named by two words in front of its code (`Proto.CodeLinks`), so an instruction that needs them loads them through the code pointer, and a call and a return load one pointer where they loaded three. With fewer values to keep across instructions, the bodies of the instructions spill less to the native stack. A step routine reads the function anyway to find its code, so it takes both from the function, and it keeps the index of its frame, which tells it without a load whether the instruction kept its frame.

A call and a return of `local function f(x) return x end` took 5.9 ns in the loop that the interpreter ran before this work and 3.6 ns after it, against 3.0 ns in the interpreter of LuaJIT. `fib` went from 0.062 s to 0.045 s with the JIT off, `methods` from 0.250 s to 0.205 s, and `closures` from 0.091 s to 0.081 s. Later work on the same path (`interp.md`) took the call and the return from 126 to 108 machine instructions and `fib` to 0.034 s, ahead of the interpreter of LuaJIT at 0.036 s. The table in `tests/bench/README.md` has every benchmark.

## Tier-up

A function has a counter that starts at the threshold, 60 events by default. The events are calls, loop iterations, and numeric loops about to start.

- Native code counts a call exactly when it reaches a function that has no code yet, and so does a call from a native function.
- The `warm` interpreter loop samples. Calls and backward jumps decrement a budget held in a machine register. When it reaches zero, the running function is charged for the whole period, and the next period gets a different length between 5 and 12, so a regular program cannot hide a function from the samples.
- A numeric `for` loop of 16 or more iterations charges its function for the whole count when it starts. A long loop therefore compiles before its first iteration, and its loop instruction counts nothing.

Baseline code counts in turn. Its call entries and backward branches decrement a second counter of the function, and at zero the optimizing tier looks at the function or at the loop (`opt.md`).

A function that reaches zero is compiled at once. The interpreter then leaves its loop with the frame at an instruction boundary, and native code picks it up there. This covers the program that is one long top-level loop.

Counting in memory at every call and loop iteration cost the interpreter up to 17 percent, and any counting in the plain loop changed its register allocation enough to cost several percent. That is why the counters live in a separate instantiation: a state whose JIT is off runs the `fast` loop, which is the same code as a build without the JIT.

Functions with more than 30 000 instructions stay in the interpreter. A long function emits its out-of-line code and its constants at intervals of 64 KB of straight-line code, so that every conditional branch and every constant load stays in range on aarch64.

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
| `call` | A callee with native code and fixed parameters is entered in native code through its call entry. A native function is called through a helper that mirrors the interpreter. |
| `ret0`, `ret1` | A lean frame returns in native code when nothing needs closing, to the address its caller left in the frame. |
| `tailcall` | A callee with native code and fixed parameters is entered through its tail entry, which rewrites the running frame in place. A native function is called through a helper, and one result returns as `ret1` does. |
| `getfield`, `gettabup` | The slot prediction of the inline cache, tested and followed inline. |
| `setfield`, `settabup` | The same for a key that is present. A key that is absent from the empty node its probe reaches is added inline, which is what a constructor does. |
| `self` | The prediction in the receiver, then `__index` of its metatable through two more predictions. A string receiver starts at the metatable of strings. |
| `gettable`, `settable`, `getindex` | An integer key inside the array part, for every element kind. A string key takes the inline cache through a helper. |
| `len` | The character count of a string is a load. A table takes a helper. |
| Everything else | The step routine. |

The emitter writes a value as its two 64-bit words and copies it as two words. A value is often written just before it is copied, for example a result that is returned at once, and a 16-byte load would wait for both stores to leave the store buffer. Fresh registers of a callee are cleared with one 16-byte store each. These two rules were worth a quarter of the time of a call.

## Table accesses

The interpreter caches a string-keyed access by predicting the hash node that held the key the last time (`tables.md`). A hit compares the key in the predicted node and uses the value next to it. Native code runs exactly that hit inline, and every other outcome calls the helper that runs the whole fast path of the interpreter (`interp.fast`), which also records the new prediction. When the helper declines too, the step routine runs the instruction.

- **Field reads** (`getfield`, `gettabup`). The receiver is a table, the predicted node exists and holds the key, and its value is something other than nil. A nil value goes to the helper, because `__index` may apply.
- **Field stores** (`setfield`, `settabup`). The table is writable and has no metatable, or one whose absence cache says it lacks `__newindex`. A key in the predicted node is overwritten. A constructor stores into a fresh table, where the predicted node is empty. The store then walks the probe sequence of the key from its first node, and when it reaches the predicted node over nodes that hold other keys, the value is something other than nil, and the load factor allows one more key, it writes the key and the value there. This is what `table.storeStr` does for an absent key. Both stores clear the absence cache of the table, as the interpreter does.
- **Method lookups** (`self`). A method that the receiver holds is a field read. Otherwise the probe sequence of the key proves that the receiver lacks it, ending at an empty node or after visiting every node of a full part, and the lookup takes the first step of `interp.indexChain`: the absence cache of the metatable allows `__index`, the second prediction finds `__index` and it names a table, and the third prediction finds the method in that table. A string receiver enters at the second step with the metatable that all strings share.
- **Array reads and stores** (`gettable`, `settable`, `getindex`). The key is an integer inside the array part. An unboxed part yields its word with the kind as the tag, and the word that stands for nil goes to the helper. A boxed part yields its value. A store into an unboxed part takes a number of the kind of the part whose bits differ from the nil word, and a store into a boxed part takes any value. A store that changes the kind of the part goes to the helper, and through it to the general path that boxes the part.

A store of a collectable value runs the write barrier of the interpreter. The inline part is the test of the barrier bit of the table, and the slow part is a call to `gc.barrierTable`, which chooses between the backward barrier and the forward barrier of a large table (`gc.md`). A store that adds a key passes the key as well. Unboxed array parts hold numbers, so stores into them need no barrier.

### Layout facts

Native code reads table memory directly, so it depends on where fields are. `table.layout` and `interp.layout` name every such fact: the offsets of the fields of a table and of a hash node, the size of a node as a shift, the element kinds as bytes, the word that stands for nil, the bit that the barrier tests, the offsets of the three predictions in an inline cache entry, and the bits of the absence cache. Each fact is computed from the declarations with `@offsetOf` and its relatives, so moving a field moves the offset that native code uses. The assumptions that the templates build in, such as a node size that is a power of two or an element kind that equals the tag it holds, are compile-time assertions next to the facts. The offsets of the pointer and the length of the hash part are measured when a function is compiled, because the language leaves the layout of a slice open. Every offset into a table that the emitter uses is one of these names.

## Calls between compiled functions

Every compiled function with fixed parameters has two entries besides the code of its instructions.

The **call entry** does what `interp.enterLus` does. The caller passes the closure, the pc to save, the base of the new frame, the wanted result count, and the argument count in registers. The entry tests for pending finalizers, for room in the frame list, and for room on the stack, and returns to the caller with nothing changed when one of them fails, so that the step routine makes the call. Otherwise it pushes a lean frame with six stores, clears the registers of the callee, and runs into the first instruction. The fields that are the same for every lean frame are neighbors in the frame, so pairs of them take one store.

A **lean return** tests that the running frame is lean and that no hook is set, pops the frame, and jumps to the address the frame holds. A function that creates a closure over one of its registers tests for open upvalues of its frame and closes them with a call to `helpers.closeUpvals`, which returns to the lean return. A function that contains a `tbc` or `tforprep` instruction tests for to-be-closed variables of its frame. The code after the call in the caller adjusts the result count, as `interp.fast.finishLean` does.

A lean frame that needs the general return, such as the frame of a function with a variable to close or with several results, runs the step routine of its return. The step routines of `ret`, `ret0`, and `ret1` leave the address that the frame held for `jit.dispatch`, which hands it out once. The caller then continues where a lean return would have taken it, with the result count in the register that the code after a call reads. That code stores nil into the results after the first of a call that wants two or more, so such a call continues in baseline code. A caller that runs in optimized code therefore stays in its unit. `closures.lus`, whose optimized loop calls such a function, went from 97 to 89 ms on aarch64, ReleaseSafe, run natively in a Linux VM on an Apple silicon Mac, best of 5. The upvalue close in the lean return then took it from 1074 to 849 ms under qemu-arm, best of 5.

The **tail entry** does what the closure branch of the interpreter's `tailcall` does. It moves the callee and its arguments down to the return slot of the running frame and makes that frame the frame of the callee. What the frame owes its caller stays in it: the return slot, the wanted count, the boundary and lean flags, the finish action of a metamethod frame, and the address its caller continues at. The caller of the entry first tests that its frame has no open upvalue, and the helper `helpers.tailcall` handles the frame that has one.

A `GETTABLE` whose key register holds a string probes the hash part inline in its out-of-line path, as `table.findStr` does, when the key is interned and the part has room, and it calls the helper only for a full part, a key that is not interned, or an absent key whose table may have `__index`. Five million lookups of string keys held in registers went from 0.023 s to 0.018 s in baseline code. `SETTABLE` with such a key probes the same way for a key that the table already holds, live or dead, checks that the store is raw, writes the value, and runs the table barrier, and a new key goes to the helper, which inserts it.

`CONCAT` and `INTERP` call `helpers.concatShort`, which runs `ops.joinShort` on the registers in place, and take the step routine only when it declines: a float, an exact number, a metamethod, a long result, or an error. `"k" .. n` went from 16.6 ns to 12.7 ns. The two took lru from 1.01 s to 0.97 s, with 4 to 7 percent fewer instructions.

A **frameless native call** runs the common case of a native function without pushing a frame. A native may name a leaf function, its fast part, which reads its arguments in place, returns one result or declines, and never raises, allocates a frame, calls back into Lus code, or yields. The result comes back in two registers, and a decline is a value with the tag of an internal object, which no Lus value carries. `interp.callNative`, which both tiers use for every call of a native, tries the leaf first and stores its result as a return would. The interpreter's `call` tries the leaf before anything else and continues with the next instruction right away, since a leaf changes neither the frames nor the hooks. A leaf that declines leaves nothing changed, and the full native then runs the call from its start. The full native begins with the same leaf, so each builtin keeps one implementation of its fast case. `setmetatable` and `string.sub` have leaves: the first for a table without a metatable that receives a metatable known to lack `__gc`, and the second for a string with integer positions. `tonumber` has one for a single number or string argument, `string.lower` and `string.upper` for a string of up to 512 bytes, and `string.byte` for one position inside an ASCII string. With them the aggregation loop of the csv program went from 0.163 s to 0.144 s, and the whole csv and wordfreq programs ran 8 and 7 percent faster. A native whose leaf computes only its first result sets `leaf_first`, and the leaf then runs only for a call that wants at most one result. `string.gsub` has such a leaf for a string replacement or a table without a metatable, and `string.find` one that returns the start of the match, which needs no captures. A pattern error or anything that would run Lus code declines, and the full native raises it. They took the aggregation loop of csv from 0.149 s to 0.138 s and the rendering of template from 0.696 s to 0.668 s. `string.format` has a leaf for arguments that are numbers and strings, which runs the same conversions as the full native and declines on `%q`, an exact integer, a value that needs `__tostring`, or any error. It took the rendering of template from 0.67 s to 0.645 s.

A call and return between two compiled functions is about 73 machine instructions and 16 stores on aarch64, where the first version of the tier took about 90 and 25.

A function that the optimizing tier compiled for **direct entry** has another call entry (`opt.md`). It pushes no frame. It checks the types of the arguments in their slots, calls the optimized body with them in machine registers, stores the result into the slot of the called function, and continues in the caller where a lean return would. The caller passes it the same registers as any call entry, so the `call` template is the same for both.

## Executable memory

Each state owns an arena (`jit/mem.zig`) of 1 MB chunks. A block is carved out of a chunk for each function, the bookkeeping lives outside the chunks, and a chunk with no blocks left returns to the system. The collector frees the block of a function when it frees the function, and closing the state unmaps every chunk. A worker has its own state, so it has its own arena and its own code.

On Apple Silicon the chunks are mapped with `MAP_JIT`, and the thread switches to write mode only while a finished function is copied in. Elsewhere the chunks are mapped readable, writable, and executable. A system that refuses such a mapping turns the JIT off for that state, and the program runs interpreted.

Code is position independent. Addresses of runtime routines and of constants are absolute, which is safe because the collector never moves an object and a function keeps its constants alive for as long as its code exists.

## Controls

- `zig build -Djit=false` builds without the JIT. The WebAssembly build compiles to WebAssembly modules that its host instantiates (`wasmjit.md`). Every target other than aarch64 and x86-64 on macOS and Linux and WebAssembly has none.
- `LUS_JIT=off` interprets everything. `LUS_JIT=eager` compiles every function on its first call, which is what the test suites use. `LUS_JIT=on` is the default, and it also runs the optimizing tier on top of this one (`opt.md`). `LUS_JIT=baseline` runs this tier alone, as `eager` does.
- `LUS_JIT_THRESHOLD=N` sets the number of events before a function compiles.
- `debug.jit()` returns the setting first, and `debug.jit(f)` tells first whether `f` has native code. The further results describe the optimizing tier.
- A host written in Zig calls `jit.configure`.

## Measurements

Wall times in seconds, best of fifteen runs that alternate between the configurations, ReleaseFast on an Apple silicon Mac. "off" is the JIT build with `LUS_JIT=off`, which runs the plain interpreter loop. "first JIT" is the tier as it first merged, with table accesses through helpers and the frame of a call copied from an image. `luajit -joff` is LuaJIT 2.1 with its JIT disabled, and `luajit` is LuaJIT with its tracing JIT.

| benchmark | off | first JIT | JIT | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.235 | 0.214 | 0.152 | 0.247 | 0.039 |
| closures | 0.095 | 0.078 | 0.071 | 0.133 | 0.125 |
| data | 0.034 | 0.034 | 0.032 | 0.273 | 0.051 |
| fib | 0.061 | 0.034 | 0.028 | 0.036 | 0.010 |
| gcpause | 0.410 | 0.401 | 0.398 | 0.458 | 0.409 |
| interp | 1.021 | 1.056 | 1.010 | 2.001 | 1.280 |
| loop | 0.220 | 0.145 | 0.143 | 0.250 | 0.092 |
| methods | 0.294 | 0.300 | 0.184 | 0.241 | 0.007 |
| patterns | 0.205 | 0.211 | 0.202 | 0.261 | 0.256 |
| strings | 0.178 | 0.181 | 0.178 | 0.249 | 0.205 |
| tables | 0.189 | 0.196 | 0.170 | 0.163 | 0.125 |
| unicode | 0.079 | 0.100 | 0.065 | 0.032 | 0.005 |

Every row runs at least as fast in native code as interpreted. The three rows that the first version made slower gain the most from the inline table accesses: `methods` runs 1.6 times faster than interpreted, `arrays` 1.5 times, and `tables` gains 10 percent. `methods` also gains from the tail entry and from the native tail call, because its constructor ends in `return setmetatable(...)` and its method in `return Point.new(...)`. `fib` gains from the leaner call and runs 2.2 times faster than interpreted. `arrays`, `closures`, `fib`, `loop`, and `methods` are ahead of LuaJIT's interpreter.

`unicode` gains in both Lus columns. A method call on a string used to look the method up through the generic index path, and the string fast path of the interpreter now covers it, which took the interpreter from 0.096 to 0.079. The rest of that row is the string library: finding a character position in a long non-ASCII string, and interning the result. It stays behind LuaJIT, which slices bytes.

`tables` spends half its time in the collector, which marks three million tables that stay alive, and most of the rest in the allocation of those tables. That is where the distance to LuaJIT's interpreter on that row lay. Exact hash parts for small records (`tables.md`), prefetching in the marker, and leaving the heap to the exit of the process (`gc.md`) later closed it, and frameless natives with inline method lookups took `methods` ahead of LuaJIT's interpreter as well. The table in `tests/bench/README.md` has the current numbers.

The benchmarks that live in the runtime (`data`, `gcpause`, `interp`, `patterns`, `strings`) run the same in both tiers. Their two Lus columns differ by less than the noise of the measurement, which is about one percent, and over 31 alternating runs the medians of `strings` are 0.1794 interpreted and 0.1796 in native code.

The "off" column moves by a few percent between builds with the code layout of the interpreter loop, which shifts whenever the loop changes. `closures`, `fib`, and `methods` moved by up to 5 percent that way during this work, in both directions.

LuaJIT's tracing JIT remains several times faster than this tier alone on `fib`, `methods`, `arrays`, and `unicode`. Closing that distance takes what a baseline tier leaves out by design: values kept in machine registers across instructions, type feedback, and allocation sinking. The optimizing tier adds them for code that stays hot, and `opt.md` has the numbers with both tiers.

## Open ends

- Allocation in native code. `newtable` and `closure` run their step routines, and a table constructor is dominated by them.
- String keys held in registers (`t[k]` with a string `k`) take the inline cache through a helper.
- The length of a table takes a helper, which searches for a border.
- A call entry still tests for pending finalizers, for room in the frame list, and for room on the stack, and clears the registers of the callee. The call of the interpreter leaves the registers as they are and leaves pending finalizers to the next safe point (`interp.md`), and the call entry can do the same.
- Windows. The emitter follows the System V convention on x86-64, and the arena uses `mmap`.
- Systems that forbid writable and executable mappings run interpreted. Mapping the code twice, once writable and once executable, would lift that.
- Warm starts, binary chunks that compile the functions a profiling run found hot, were built and measured and are kept out (`warmstart.md`).
- The embedding interface in C has no JIT control yet. A state created through it uses the default setting, and a host written in Zig calls `jit.configure`.
