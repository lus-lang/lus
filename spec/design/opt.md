# The optimizing tier

Above the baseline JIT (`jit.md`) sits a second compiler for code that stays hot. It builds an intermediate representation in static single assignment form from the bytecode of one function, predicts the types of the values from what the running program holds, keeps those values unboxed in machine registers, and guards every prediction. A guard that fails writes the values back to the frame and continues in baseline code at the instruction the guard belongs to. This note describes when the tier compiles, how it predicts, what its representation and its passes do, how optimized code is left, and what it costs and gains. The tier lives in `runtime/src/jit/opt` and exists on aarch64 and x86-64.

## Where it sits

Frames belong to every tier. Optimized code runs the same frame, on the same Lus stack, as the interpreter and the baseline code, and it keeps the four pinned registers of the baseline code. So the tiers jump to each other at instruction boundaries, and everything that reads frames (the collector, tracebacks, the debug library, coroutines, exception tables) keeps working unchanged.

An instruction that the tier has no typed form for runs through its baseline template, emitted by the baseline emitter itself inside the optimized code. Generic loops, closures, string building, and the calls that are neither compiled inline nor made directly work this way. Before such a template, every live register goes to its slot, and afterwards every register lives in its slot. The tier therefore adds typed code where it pays and leaves the rest at baseline speed.

A function that needs no template at all is compiled for direct entry. Its registers live in machine registers alone, a call of it from optimized code is a native call, and its frame is built only when optimized code is left (see "Direct calls").

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

## Direct calls

A call that is too large to compile inline, or that calls the function it is in, is made directly when its callee was compiled for direct entry. `fib` is the model: each activation calls itself twice, and nothing in it needs a frame.

### Direct entry

A function compiled from its first instruction is built for direct entry first. The builder starts it with its closure and its fixed parameters as values, typed as the arguments of the running frame are, and with every other register nil. No register ever lives in its slot. A return becomes a native return that carries the result in two machine registers, the payload and the tag. The build succeeds when the function needs no baseline template and no instruction that reads or writes a slot. Anything else builds the function again with a frame. That covers a function with a variable number of arguments or more than four parameters, one that makes a closure over a register, a tail call, a call that stays a plain call, a register whose type differs between two paths, and an allocation that reaches the collector check.

The closure travels in the first register that holds values and the parameters in the ones after it, each as its payload, with a float as its bits. The parameter types are part of the entry: a direct caller has arguments of exactly those types.

### The three ways in

Optimized code for direct entry has one body and three entries around it.

- A **direct call** from optimized code enters the body itself. It is a native call instruction, and the native stack holds one small frame per activation: the values of the caller that live across the call, and the return address.
- A **call from baseline code** enters through a thunk that takes the registers of every call entry (`jit.md`). It checks the argument types in their slots, keeps what a frame for the callee needs in its own native frame, and calls the body. Afterwards it stores the result into the slot of the called function and continues in the caller.
- A **frame in place**, which the interpreter or a step routine pushed or which a tail call took over, enters through a thunk that loads the parameters from the frame, calls the body, and returns the result as the templates of `ret0` and `ret1` do.

An argument of another type sends a call from baseline code to its step routine, and a frame in place to baseline code through an exit that is recorded against the first instruction. A function that keeps getting other types is built with a frame from then on.

### The caller

The caller guards that the callee is the predicted function. A function that calls itself compares the closure it loaded with its own, and a call into other code compares the function of the closure and tests a word of the callee's code that retiring the code clears. Then the arguments move to the registers of the convention, and the call follows.

The callee returns its result with its tag. The caller predicts the type and guards the tag. For a call into other code the prediction is the type that every return of the callee yields. For a call of the function itself, the builder starts with an integer, looks at the returns it built, and builds again when they yield another type. A result of another type leaves optimized code after the call, with the result in its register, and counts against the call.

A direct callee is typed code that the builder knows. It lists the classes of memory that the callee writes, so a call forgets what the block knew about those classes alone. In `fib` the callee writes nothing, so the second call reuses the closure that the first one loaded from the upvalue.

### Frames exist when something reads them

While a chain of direct calls runs, the frame list and the Lus stack show only what was there when the chain started. Each call site has a snapshot of its caller: the instruction after the call, the registers that are live across it, and the closure in the slot of the called function. Those values live in the native frame of the caller, because every value that is live across a direct call takes a slot there.

Directly entered code calls nothing but direct callees and a few runtime routines that neither allocate through the collector nor look at frames. So nothing can read the frames of a thread while a chain runs. The one way out of a chain other than returning is an exit, and an exit builds the frames first. `opt.rt.deoptDirect` walks the native stack from the activation that leaves to the entry that started the chain. The return address in each native frame names a call site, the site names a snapshot, and the walk pushes for every activation the frame the interpreter would have pushed, clears its registers, and writes the values of the snapshot from the native frame. A call site inside a call that was compiled inline pushes the inline frames too. Then the exit proceeds as any other: it writes the registers of the innermost activation and continues that frame in baseline code. The native stack returns to where the entry sequence left it, and every other frame of the chain continues in baseline code at the instruction after its call when its callee returns.

Tracebacks, errors, `catch`, the collector, coroutines, hooks, and the debug library therefore see complete frames whenever they look. An error inside a chain is a failed guard followed by the error that baseline code raises. A yield happens in a function that baseline code or the interpreter runs, above frames that an exit built. A thread with a hook runs in the interpreter.

### The stacks

A chain uses native stack where the interpreter uses the Lus stack, and both have limits.

The call that starts a chain enters the callee at its chain entry, which sets the lowest address the chain may take the native stack to. Every activation compares the stack pointer with it before anything else and leaves through an exit that is kept out of the records. The address comes from two limits.

- **The native stack.** The outermost entry into Lus code asks the system for the stack of the thread and keeps a floor 128 KB above its low end. The runtime builds the frames of a chain in that reserve. On a stack the system does not describe, a chain gets 160 KB below the entry.
- **The Lus stack.** An activation covers at least as many bytes of native stack as its call takes slots, and the code of every function knows the most slots that a chain starting in it covers per sixteen bytes. The chain entry turns the slots that the Lus stack has left, less 1024, into bytes. A chain that stays above that address stays inside the Lus stack.

When the Lus stack has fewer than 1024 slots left, a chain entry declines, and the call runs in baseline code. The call that finds no room is therefore made by the interpreter's own code, which raises the stack overflow error at the depth where the interpreter raises it, and no activation runs that the interpreter would not have run.

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
- `LUS_JIT_DIRECT=off` keeps optimized code from calling optimized code directly. A number gives a chain of direct calls that many bytes of native stack, which makes chains short and exits frequent for testing.
- `LUS_JIT_DUMP=1` prints the intermediate representation of every compilation, with the place of every value, the reasons the builder started over, and every exit.
- `debug.jit()` returns the setting of the baseline tier, the setting of the optimizing tier, the number of units compiled, and the number of exits taken. `debug.jit(f)` returns whether `f` has native code and whether it has optimized code in use.

## Tests

`tests/conformance/opt_test.lus` warms each subject with one kind of operand and then makes every kind of guard fail: operand types of arithmetic and comparisons, integer overflow, division by zero and by minus one, table shapes, metamethods that appear in a loop, array kinds and bounds, upvalues, inline callees that change or raise, unallocated tables on every path, the collector and finalizers, hooks, coroutines, and the debug library. For direct calls it leaves optimized code deep inside recursion and checks the frames that `debug.getinfo` counts, the locals of every activation, the traceback of an error, a yield and a collection below the frames that the exit built, calls between two pieces of optimized code, recursion through a call compiled inline, and the depth at which the stack overflows. The whole conformance suite also runs under `LUS_JIT=opt-eager`, on x86-64 under Rosetta, with a collector that runs at every 97th allocation point and verifies the heap, and with `LUS_JIT_DIRECT=1024`, which ends every chain of direct calls after a few activations.

## Measurements

Wall times in seconds, best of nine runs, ReleaseFast on an Apple silicon Mac. "off" is `LUS_JIT=off`, "baseline" is `LUS_JIT=baseline`, and "optimizing" is the default with both tiers. `luajit -joff` is LuaJIT 2.1 with its JIT disabled, and `luajit` is LuaJIT with its tracing JIT.

| benchmark | off | baseline | optimizing | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.238 | 0.153 | 0.034 | 0.247 | 0.038 |
| closures | 0.081 | 0.072 | 0.064 | 0.133 | 0.126 |
| data | 0.034 | 0.033 | 0.027 | 0.278 | 0.050 |
| fib | 0.045 | 0.029 | 0.009 | 0.036 | 0.010 |
| gcpause | 0.414 | 0.416 | 0.416 | 0.467 | 0.425 |
| interp | 0.901 | 0.898 | 0.917 | 2.009 | 1.281 |
| loop | 0.221 | 0.144 | 0.057 | 0.252 | 0.091 |
| methods | 0.205 | 0.181 | 0.006 | 0.247 | 0.006 |
| patterns | 0.198 | 0.200 | 0.200 | 0.260 | 0.256 |
| strings | 0.140 | 0.141 | 0.144 | 0.246 | 0.207 |
| tables | 0.155 | 0.152 | 0.143 | 0.165 | 0.126 |
| unicode | 0.050 | 0.040 | 0.007 | 0.031 | 0.004 |

`methods` gains the most. Its loop calls a method that builds a new object from two fields of the old one. The tier compiles the method and the constructor inline, keeps the object unallocated around the loop, and moves the method lookup in front of it. `arrays` gains from typed element loads and stores whose kind and bounds checks sit in front of the loops. `loop` is integer arithmetic in registers. `unicode` takes the length of a substring on every iteration, which the tier computes from the positions alone.

`fib` is all calls, and the tier makes them directly. Each activation takes `n` in a machine register, calls itself twice with a native call, and returns its result in a register, so the recursion touches neither the frame list nor the Lus stack. It runs three times as fast as in baseline code, where every call pushes a frame, and level with LuaJIT. Deep recursion gains less: a function that calls itself 100 000 deep, a hundred times over, takes 0.049 s where baseline code takes 0.068 s. `tables` spends most of its time allocating three million tables that stay alive and marking them. The benchmarks that live in the runtime (`data`, `gcpause`, `interp`, `patterns`, `strings`) run the same in every Lus column.

## Open ends

- A function that needs a baseline template keeps its frame, and so do its calls. Tail calls are the common case: a function that calls itself in tail position runs through the tail entry of the baseline tier.
- Two functions that call each other are compiled one after the other, and the first is built before the second has code to call, so both keep their frames.
- A direct call returns at most one result and passes at most four parameters.
- Recursion that outgrows the native stack before the Lus stack leaves its chain once, and the frames that the exit built return through the general return of the interpreter.
- Compiling a recursive call inline one level deep was tried on `fib` and gained nothing. The join after the inline body forgets what the block loaded, so each half loads and guards the closure again.
- A table with an array part, and a table stored into another unallocated table, are allocated at once.
- Generic `for` loops over `pairs` and `ipairs` run through baseline templates, which sends every live register through its slot on each iteration.
- Float `for` loops, loops with a step other than one or minus one, `pow`, float modulo, shifts, and string comparison have no typed form.
- A value that is live across a call into the runtime lives on the native stack for its whole life. Splitting intervals around such calls would keep it in a register in the rest of the loop.
- Memory running out while an exit allocates the tables of its snapshot raises the memory error at the instruction the exit continues at.
- Units stay in memory until their function is collected, because a frame further down the stack may still return into one.
- The tier is native only. The WebAssembly build runs the baseline tier.
