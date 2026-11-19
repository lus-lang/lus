# The optimizing tier

Above the baseline JIT (`jit.md`) sits a second compiler for code that stays hot. It builds an intermediate representation in static single assignment form from the bytecode of one function, predicts the types of the values from what the running program holds, keeps those values unboxed in machine registers, and guards every prediction. A guard that fails writes the values back to the frame and continues in baseline code at the instruction the guard belongs to. This note describes when the tier compiles, how it predicts, what its representation and its passes do, how optimized code is left, and what it costs and gains. The tier lives in `runtime/src/jit/opt` and exists on aarch64 and x86-64.

## Where it sits

Frames belong to every tier. Optimized code runs the same frame, on the same Lus stack, as the interpreter and the baseline code, and it keeps the four pinned registers of the baseline code. So the tiers jump to each other at instruction boundaries, and everything that reads frames (the collector, tracebacks, the debug library, coroutines, exception tables) keeps working unchanged.

An instruction that the tier has no typed form for runs through its baseline template, emitted by the baseline emitter itself inside the optimized code. Calls, returns, generic loops, closures, and string building work this way. Before such a template, every live register goes to its slot, and afterwards every register lives in its slot. The tier therefore adds typed code where it pays and leaves the rest at baseline speed.

## When it compiles

Baseline code counts. The call entry of a function and every backward branch decrement a counter of the function, which starts at 120. When the counter reaches zero at a call, the function compiles from its first instruction, and calls enter the optimized code from then on. When it reaches zero at a backward branch, the code compiles from the first instruction of that loop, and the frame continues there at once. A compilation that starts at a loop covers everything the loop reaches, including the code after it.

One function can have several pieces of optimized code, called units: one from its first instruction and one per loop that became hot by itself. A function gets at most twelve units over its life, and functions of more than 1500 instructions stay in baseline code.

## Predictions

The builder needs the type of every value it wants in a register. It has three sources.

- **The running frame.** A compilation starts while the function runs, so the registers hold real values. The builder follows them as samples: through moves, through the fields and the array slots of the tables they name, through upvalues, and into the functions it compiles inline. A sample is only a prediction, and every use of one is guarded.
- **The objects in those samples.** A field access is compiled against the hash node that holds the key in the sample table, a method lookup against the metatable of the sample, and an array access against the kind of its array part. These are the facts that the inline caches of the interpreter predict, read from the objects themselves.
- **Earlier exits.** When a guard fails, the exit records which instruction it belongs to and which tags its operands held. The next compilation of the function uses those tags.

An instruction whose guards failed twice makes its unit retire, and the function compiles again with fresh samples. An instruction whose guards failed four times runs through its baseline template from then on. So a site that really sees many types settles at baseline speed, and the rest of the function stays optimized.

## The representation

A function is a graph of blocks, and a block is a list of instructions (`ir.zig`). Every value has a static type: nil, boolean, integer, float, or one of the object types. Its machine form is the payload alone, an integer, a float, or an address. Instructions are low level: loads and stores with a base and a displacement, integer and float arithmetic, comparisons, and guards. A table access is spelled out as the loads and guards that the baseline template performs, which lets the ordinary passes share and move its parts.

The builder (`lower.zig`) walks the control flow graph in reverse postorder. For every register it knows either a typed value, or that the frame slot holds the register, possibly with a known type. Reading a register whose type is only predicted emits a guard on the slot and a load. Where control flow joins, registers that hold values of one type get a phi, and registers that disagree go back to their slots. A loop header creates its phis from the state in front of the loop, and the edge that closes the loop completes them. When the loop changes the type of a register, the builder starts over with that register kept in its slot across the loop.

A type that was known before a baseline template is a prediction after it. The template may call anything, and the debug library can assign to a local of a suspended frame.

### Snapshots

Every guard names a snapshot: the instruction to continue at, and for each live register that is ahead of its slot, the value to write there. Live means that some later instruction may read the register, or that a visible local variable lives in it, so that `debug.getlocal` sees every local after an exit. Registers that a closure captures always live in their slots.

All guards of one bytecode instruction come before its first effect and share one snapshot, so a failing guard runs the whole instruction again in baseline code.

## Leaving optimized code

A failing guard jumps to a short stub that names its snapshot and joins one common sequence per unit. That sequence saves the machine registers and calls `opt.rt.deopt`, which writes every value of the snapshot to its slot, sets the saved pc, records the exit, and returns the address of the baseline code for that instruction. Baseline code exists for every function that has optimized code. A function that was compiled inline and has no baseline code continues in the interpreter.

Errors need nothing more. Whatever can raise is either a guard, which leaves first, or a baseline template, which raises as it always does with the frame complete.

## The passes

- **Local value numbering** happens in the builder. Loads of the same word, guards of the same condition, and arithmetic on the same operands merge within a block. Every load carries the class of memory it reads (a hash node key, a hash node value, an array slot, an upvalue, and so on), and a store ends what the block knows about its class. A store also makes the stored value the result of a later load of that word.
- **Phi simplification** removes phis that merge one value.
- **Loop-invariant code motion** (`passes.zig`) moves arithmetic, loads, and guards in front of a loop when their operands are defined outside it and the loop writes nothing of the class they read. A load names the guard that makes it safe, and moves only together with it. A guard that moved continues at the first instruction of the loop, before anything in the loop ran. A loop that runs a baseline template is left alone.
- **Dead code elimination** drops what nothing reads, including values that only a removed guard needed.

### Array loops

The index of a numeric `for` loop that counts up by one is known to run from its first value to its first value plus its count. An array access with that index guards once that the last index lies inside the array part and that the first is at least one. Both operands are fixed while the loop runs, so the guard moves in front of the loop together with the load of the length and the check of the element kind. The loop body keeps the load of the element and the test for the word that stands for nil.

A store into an array slot runs inline when the index lies inside the array part and the value fits its kind. A store site that left optimized code twice, as a loop that appends does when the array grows, keeps the inline store and takes the baseline template for every other case, so it stays in optimized code.

## Calls compiled inline

A call whose sample is a small Lus function with fixed parameters is compiled into its caller, up to three levels deep. The call guards that the callee is a closure of the same function. The registers of the callee are the slots they would be in a real frame, so its arguments need no move.

The frame of an inline callee exists only in the snapshots. A snapshot inside inline code lists every frame from the root to the innermost one, and an exit pushes them as ordinary frames before it writes the registers. Tracebacks and errors after an exit therefore show every function. A tail call inside inline code replaces the inline frame, as it replaces a real one. A callee that needs a baseline template makes the builder start over with that call as a plain call.

The tier knows a few library functions as typed operations: `math.sqrt`, `math.abs` on a float, `math.floor` and `math.ceil` on an integer, `setmetatable` on a table without a metatable, `string.byte` with one position, and the length of `string.sub`, which follows from the character count and the positions without making the substring. Each guards that the callee is that very library function. A method call on a string finds the method through the metatable that all strings share.

## Tables that are never allocated

A record constructor in optimized code allocates nothing at first. The builder keeps the table as its fields: a list of keys, the hash node each key would occupy, and the value of each field. Reading a field yields the value. A method lookup goes through the metatable that `setmetatable` gave the table. Snapshots describe such a table field by field, and an exit allocates it and fills it in before it writes the registers.

A use that needs the table itself allocates it on the spot: storing it into another table or an upvalue, passing it to a baseline template, indexing it with a register key. A table that nothing needs is never allocated.

Where control flow joins, tables that are unallocated on every edge and have the same keys merge into one, whose fields are phis. To carry a table around a loop this way, the tier runs the first iteration of a small loop in a copy in front of the loop. After that copy, the table that the loop carries from one iteration to the next has the same shape on the entry edge and on the closing edge, so the loop header gives it phis for its fields and the loop body allocates nothing. In `p = p:add(d)`, the method allocates a new point on every iteration, and the optimized loop adds two numbers.

When such a table gets a metatable inside a loop that carries a table with a metatable from the same sample, the builder guards that the two metatables are the same object. The metatable is then one value for the whole loop, and every lookup through it moves in front of the loop.

### The collector

An allocation in optimized code first checks, inline, whether a collection is due. If so, an out-of-line stub writes the live values to their slots, where the collector finds them, and runs the step. What an unallocated table refers to lives only in machine registers, so the stub parks those values in stack slots above the live registers while the collector runs. Values that a block read from memory as objects are read again after such a point, because the collector clears entries of weak tables.

Tables that are never allocated put no pressure on the collector, and a program may wait for a finalizer while making only such tables. So every unallocated table adds its size to a counter of the state. When 4 MB went by, or as many bytes as the heap holds if that is more, optimized code leaves through the usual exit, and the exit runs a full collection. A table that is allocated after all gives its size back to the counter, since its allocation counts toward the heap like any other, and the allocation checks for pending finalizers as a constructor does. On `tables.lus`, where every record ends up in a list, counting the records twice had made the exits run a full collection each time the heap doubled, on top of the collector's own cycles.

While the stub of an allocation runs the collector, a slot whose snapshot value is an unallocated table holds nil. The value that slot held before belongs to the past of the program, which may have dropped it, so the collector must be free to collect it.

A metatable with `__gc` keeps `setmetatable` a real call, which allocates the table and registers its finalizer.

## Registers

The allocator (`regalloc.zig`) is a linear scan over live intervals. A value gets one place for its whole life: a machine register, or a slot in a block of the native stack that the unit owns. Values that are live across a call into the runtime take a stack slot, since every register the tier allocates belongs to the callee there. Liveness across those calls is computed exactly, block by block. Constants take no place, and the code generator writes them where they are used. A phi and its arguments prefer one register, which makes most loop phis free.

The tier allocates 13 integer and 16 float registers on aarch64, and 7 integer and 8 float registers on x86-64. Optimized code leaves its block of the native stack before every baseline template and before every exit, so baseline code and other units find the native stack as they expect it.

## One code generator

`codegen.zig` is written against the assembler interface that `a64.zig` and `x64.zig` share, as the baseline emitter is, so the tier has one code generator for both targets. The assemblers gained three-operand arithmetic, float moves, indexed loads, and a floor division that preserves the registers the x86-64 division needs.

## Controls

- `LUS_JIT=on`, the default, runs both tiers. `LUS_JIT=baseline` runs the baseline tier alone, and so does `LUS_JIT=eager`, which compiles every function on its first call.
- `LUS_JIT=opt-eager` sends every function through both tiers on its first call. The test suites use it to run the whole conformance suite through optimized code.
- `LUS_JIT_OPT_THRESHOLD=N` sets the number of calls and loop iterations in baseline code before the optimizing tier compiles.
- `LUS_JIT_DUMP=1` prints the intermediate representation of every compilation, with the place of every value, the reasons the builder started over, and every exit.
- `debug.jit()` returns the setting of the baseline tier, the setting of the optimizing tier, the number of units compiled, and the number of exits taken. `debug.jit(f)` returns whether `f` has native code and whether it has optimized code in use.

## Tests

`tests/conformance/opt_test.lus` warms each subject with one kind of operand and then makes every kind of guard fail: operand types of arithmetic and comparisons, integer overflow, division by zero and by minus one, table shapes, metamethods that appear in a loop, array kinds and bounds, upvalues, inline callees that change or raise, unallocated tables on every path, the collector and finalizers, hooks, coroutines, and the debug library. The whole conformance suite also runs under `LUS_JIT=opt-eager`, on x86-64 under Rosetta, and with a collector that runs at every 97th allocation point and verifies the heap.

## Measurements

Wall times in seconds, best of nine runs, ReleaseFast on an Apple silicon Mac. "off" is `LUS_JIT=off`, "baseline" is `LUS_JIT=baseline`, and "optimizing" is the default with both tiers. `luajit -joff` is LuaJIT 2.1 with its JIT disabled, and `luajit` is LuaJIT with its tracing JIT.

| benchmark | off | baseline | optimizing | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.241 | 0.153 | 0.034 | 0.246 | 0.038 |
| closures | 0.091 | 0.074 | 0.068 | 0.134 | 0.127 |
| data | 0.034 | 0.033 | 0.027 | 0.277 | 0.050 |
| fib | 0.062 | 0.029 | 0.029 | 0.036 | 0.010 |
| gcpause | 0.407 | 0.409 | 0.409 | 0.460 | 0.432 |
| interp | 0.936 | 0.920 | 0.942 | 2.069 | 1.326 |
| loop | 0.228 | 0.149 | 0.059 | 0.256 | 0.095 |
| methods | 0.250 | 0.188 | 0.006 | 0.251 | 0.006 |
| patterns | 0.203 | 0.202 | 0.204 | 0.263 | 0.257 |
| strings | 0.146 | 0.145 | 0.145 | 0.252 | 0.221 |
| tables | 0.166 | 0.156 | 0.151 | 0.167 | 0.128 |
| unicode | 0.051 | 0.042 | 0.007 | 0.034 | 0.005 |

`methods` gains the most. Its loop calls a method that builds a new object from two fields of the old one. The tier compiles the method and the constructor inline, keeps the object unallocated around the loop, and moves the method lookup in front of it. `arrays` gains from typed element loads and stores whose kind and bounds checks sit in front of the loops. `loop` is integer arithmetic in registers. `unicode` takes the length of a substring on every iteration, which the tier computes from the positions alone.

`fib` stays where the baseline tier left it. Its time is the call itself: every call pushes a frame that all tiers share, and the tier compiles the arithmetic around the calls but leaves the calls to the baseline templates. `tables` spends most of its time allocating three million tables that stay alive and marking them. The benchmarks that live in the runtime (`data`, `gcpause`, `interp`, `patterns`, `strings`) run the same in every Lus column.

## Open ends

- Calls between optimized functions use the baseline call and return templates. Passing arguments in registers and building frames only on exit would help recursive code such as `fib`.
- A table with an array part, and a table stored into another unallocated table, are allocated at once.
- Generic `for` loops over `pairs` and `ipairs` run through baseline templates, which sends every live register through its slot on each iteration.
- Float `for` loops, loops with a step other than one or minus one, `pow`, float modulo, shifts, and string comparison have no typed form.
- A value that is live across a call into the runtime lives on the native stack for its whole life. Splitting intervals around such calls would keep it in a register in the rest of the loop.
- Memory running out while an exit allocates the tables of its snapshot raises the memory error at the instruction the exit continues at.
- Units stay in memory until their function is collected, because a frame further down the stack may still return into one.
- The tier is native only. The WebAssembly build runs the baseline tier.
