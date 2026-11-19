# The interpreter loop

The interpreter is one function, `run` in `vm/interp.zig`, whose dispatch loop is a labelled switch (`jit.md` describes its instantiations). This note records what the loop does to stay ahead of the interpreter of LuaJIT on the bench suite, and the measurements behind three designs the plan for 2.0 asked to try: handlers that tail call each other, fused instructions mined from profiles, and substring views (`strings.md`).

Every number below comes from a ReleaseFast build on an Apple silicon Mac (M4 Max) with `LUS_JIT=off`. Instruction and cycle counts are those of the whole process as `/usr/bin/time -l` reports them. Instruction counts repeat exactly from run to run. Cycle counts are the smallest of nine to eleven runs that alternate between the builds compared, and two builds that run the same instructions still differ by up to 6 percent in cycles when the code of the loop moves, so a difference in cycles smaller than that says nothing by itself.

## Measuring

`tests/bench/run.sh` gives wall times. For a change to the loop, the instruction count is the first thing to read, because it is exact:

```sh
LUS_JIT=off /usr/bin/time -l runtime/zig-out/bin/lus tests/bench/fib.lus
```

The loop runs at six to nine instructions per cycle on this machine, so the instruction count bounds the time of most benchmarks. Where a benchmark stops following it, a chain of loads and stores that every iteration waits for is the usual cause. Two such chains are described below.

## What a plain call does

`call` enters a Lus function with fixed parameters and no native code on its shortest path (`enterPlain`), and `ret0` and `ret1` leave such a frame on theirs (`fast.finishPlain`). The path keeps to the following rules.

- **The registers of the callee keep what the stack holds.** Missing parameters become nil, and every other register of the new frame is left as it is. The compiler writes a register before it reads it, so no instruction sees the old content. The collector clears the stack above the top at the end of every mark phase (`Thread.traverse`), and a slot below the top is marked, so whatever a frame finds in a register is nil or a value that is still alive. A value in such a register stays alive until the register is written or the frame returns, which is the behavior of every Lua implementation that scans frames to their top.
- **Pending finalizers wait for the next safe point.** A plain call allocates nothing. Finalizers run at loop back edges, at table allocations, and at every other call.
- **The frame count is found from the address of the frame.** The new frame is the one after the running frame, and a return stores the index of the frame that returns. A call or a return that read the count back from the thread would wait for the store of the call or return before it, which chains every call to the one before through memory.
- **A plain frame returns into the slot below its registers.** Only `enterPlain` writes the flags word `Frame.plain_flags`, and the return slot of its frames is the function slot, which sits just below the first register, so the return moves its result without loading an index.
- **The flags word of the frame is a shift of the call flags of the function.** `Proto.CallFlags` keeps `plain` and `closes` a byte apart, as the frame does.
- **The plain call comes first in the instruction.** It computes only what it needs, so the calls of natives that follow it in the same case of the switch force no spills on it.
- **The common path falls through.** The blocks that grow the stack or the frame list, read a variable argument count, fill results the function did not return, or run pending finalizers are marked unlikely, so the compiler moves them out of the way. Before that, a call and a return each jumped over two such blocks. Marking them took `fib` from 160 to 144 million cycles while the instruction count went from 1139 to 1132 million: a taken branch costs the front end of the processor more than the instruction it is.

A call and a return of `local function f(x) return x end` in a loop, with the two moves around them, took 126 instructions before this work and take 108 now. `fib` went from 1326 to 1132 million instructions and from 0.048 to 0.034 seconds.

## Operands

Signed operands are two's complement and sit at the top of the instruction or of their byte, so one arithmetic shift decodes a jump offset or a small integer. The earlier encoding added a bias, which took three instructions to remove on every jump.

Values are 16 bytes, and the routines on the paths of the loop take and return them through pointers or as their two words (`table.arrayLoad`, `table.arrayStoreAt`, `table.storeStr`, the result of a leaf native). A value passed by value through an inline function that returns it from two places lands in a stack slot, and reading it back costs a store and two loads. Copying from the node or the array slot to the register took `arrays` from 8496 to 7700 million instructions and `methods` from 6129 to 5994 million.

## Tail-call dispatch

The plan estimated that handlers which tail call each other, with the state of the loop pinned in argument registers, would beat the switch by 5 to 15 percent. The experiment instantiated the body of every opcode as a function of its own from the same definitions as the switch, the way a step routine is instantiated, under a build option. The handlers took the thread, the frame, the code, the registers, the pc, the instruction, the stop depth, and the handler table as parameters, with the calling convention that preserves no register (`aarch64_preserve_none`, `x86_64_preserve_none`), so that a call into the runtime keeps the state in place.

Three things had to be solved before the result was fair.

- Zig returns an error union only from a function with the default calling convention, and `@call(.always_tail, ...)` must sit in the handler itself. The body therefore returned to the handler, which made the one tail call.
- A handler with a call into the runtime on any path saved the link register and set up a frame on every path, because the slow path joins the fast one before the dispatch and the prologue cannot be moved into it. The first version ran `fib` in 1710 million instructions against 1326 million for the switch. Each opcode with a fast path was therefore instantiated twice: a quick handler that ends in a tail call to its twin wherever the body would call into the runtime, and the full handler, which runs the instruction again from the start. That needs every instruction to be harmless to repeat up to its first slow path, as native code already assumes.
- The values that a quick handler passes through memory had to go (see "Operands"), which helped the switch as much.

With all of that, every quick handler was free of a stack frame. The table gives instructions and cycles in millions for the switch and for the tail-call loop built from the same source.

| benchmark | switch instructions | tail instructions | switch cycles | tail cycles |
|---|---:|---:|---:|---:|
| arrays | 7700 | 7868 | 870 | 947 |
| closures | 2101 | 2135 | 352 | 349 |
| fib | 1319 | 1329 | 192 | 183 |
| loop | 7525 | 8425 | 925 | 932 |
| methods | 5994 | 6149 | 890 | 907 |
| tables | 2701 | 2797 | 440 | 432 |
| unicode | 1133 | 1218 | 183 | 171 |

`data`, `gcpause`, `interp`, `patterns`, and `strings` spend their time in the runtime and did not move. A second build of the tail-call loop that ran the same instructions with the handlers laid out differently gave 881 for `arrays`, 196 for `fib`, 854 for `methods`, and 177 for `unicode`, so the cycle columns agree within the noise of the layout.

The tail-call loop runs more instructions on every benchmark and wins none of them beyond that noise. The labelled switch already gives what the tail calls were meant to give: LLVM keeps the frame, the code, the registers, the pc, and the instruction in callee-saved registers across the whole loop and ends every case in its own indirect branch, so the simple cases are the same instructions in both. What the handlers add is one exit per handler, which every path jumps to, and a second dispatch for every slow path. The switch stays the only dispatch, and the experiment was removed. Its lasting results are the value handling above and the ordering of the plain call.

## Fused instructions

The plan asks for superinstructions mined from profiles. A build with `-Dop-profile=true` counts every pair and every run of three opcodes that the plain loop dispatches (`vm/opprofile.zig`) and prints the counts when the program ends. `tools/op-ngrams.js` runs the bench corpus that way and ranks the sequences by their share of the instructions of each program, averaged over the programs.

```sh
cd runtime && zig build -Doptimize=ReleaseFast -Dop-profile=true --prefix /tmp/lus-profile
node tools/op-ngrams.js /tmp/lus-profile/bin/lus
```

Before any pair was fused, the first pairs of the ranking were, with the mean share and the largest share in one program:

| pair | mean | largest |
|---|---:|---:|
| `add forloop` | 4.96% | 33.3% in loop |
| `settable forloop` | 4.61% | 20.0% in data |
| `forloop modk` | 2.81% | 33.3% in loop |
| `modk add` | 2.78% | 33.3% in loop |
| `mulk settable` | 2.73% | 20.0% in data |
| `getfield add` | 2.27% | 16.7% in tables |
| `gettable add` | 2.05% | 24.6% in arrays |
| `move call` | 1.91% | 12.0% in closures |
| `getupval subk` | 1.52% | 18.2% in fib |
| `subk call` | 1.52% | 18.2% in fib |

Three pairs are fused: the two with the largest mean share, and `getupval subk`, the pair with the largest share in `fib` whose second instruction has a short fast path. A pair whose second instruction is reached through a jump, such as `forloop modk`, is a pair only at run time.

A fused instruction is the first instruction of its pair with another opcode (`opc.Code`, `opc.fusions`). The second instruction stays in the code as it is. The compiler fuses when it closes a function (`opc.fuse`). Everything that reads plain opcodes (`opc.op`) sees the two instructions as written: the JIT tiers, the hooked loop, the step routines, the debugger, and a jump or a return that lands on the second instruction. Only the plain loop, the loop that counts for the JIT, and the listing of `lus --dis` see the fused opcode.

The case of a fused opcode runs the body of its first instruction and then the fast path of the second from the same definition the plain case uses (`fast.forInt`, the integer subtraction). When the second instruction needs anything else, the pc still points at it and it is dispatched as usual. That saves the fetch and the indirect branch of one dispatch.

A simpler form was measured first: the first body followed by a direct jump into the case of the second instruction. It made the whole loop slower. The second case then has two kinds of predecessors that hold the instruction word in different registers, and LLVM places the copy that reconciles them before the indirect branch of every case. `loop` went from 7526 to 7626 million instructions, `fib` from 1199 to 1241, and `arrays` from 7700 to 8033.

The form that landed gave, in millions of instructions and of cycles:

| benchmark | instructions before | after | cycles before | after |
|---|---:|---:|---:|---:|
| loop | 7526 | 7226 | 928 | 897 |
| arrays | 7700 | 7607 | 870 | 853 |
| fib | 1199 | 1185 | 164 | 159 |
| tables | 2701 | 2650 | 436 | 429 |

The other benchmarks run the same instructions as before. The set is small on purpose. Each fused opcode is another case in the loop, and a pair pays only where its second fast path is short. The ranking should be read again whenever the bench corpus changes.

## Strings in the loop

A native may name a leaf, a routine that runs its common call without a frame (`jit.md`). A leaf has the C calling convention, so its result comes back as two words in two registers and goes to the stack with one store of a pair. `string.sub` on a string of mixed text also remembers where its last range started and ended, and a range that starts within sixteen characters after the last one is found from there (`strings.md`). Together they took `unicode` from 0.042 to 0.033 seconds. Most of that came from the second change, because every call had been waiting for the positions that the call before it stored.

## Where the loop stands

`tests/bench/README.md` has the table. `fib` and `unicode` were the two benchmarks on which the interpreter of LuaJIT led this one, by 0.047 s to 0.036 s and by 0.042 s to 0.032 s.

`fib` now runs in 0.034 s against 0.036 s, and in 142 million cycles against 154 million, over 21 alternating runs. Lus runs 1132 million instructions there and LuaJIT 878 million. A call here writes a frame of 64 bytes with four stores of a pair and tests the room on the stack and in the frame list, where LuaJIT keeps a frame as one word in the stack, and the interpreter makes up for it with eight instructions per cycle against under six.

`unicode` runs in 0.033 s against 0.031 to 0.033 s from one set of runs to the next, and in 138 million cycles against 136 million. The two are level within the noise of the measurement, and Lus is the one behind when they differ. LuaJIT slices bytes there, while Lus counts characters of one to four bytes. The loop around the call is the faster part on the Lus side, 35 million cycles against 59 million, and the call of `string.sub` with its lookup in the string table is the slower one.
