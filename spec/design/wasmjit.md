# The JIT on WebAssembly

The WebAssembly build of Lus 2.0 compiles hot functions to WebAssembly. The runtime emits a small module for each function inside its own linear memory, the JavaScript host compiles and instantiates it, and the runtime calls the result through its function table. Code in the playground and in the runtime of the VS Code extension is therefore compiled the way native code is. This note describes the backend in `runtime/src/jit/wasm.zig`, the host in `packages/wasm/src/jit.js`, and what the tier gains. It builds on the baseline JIT (`jit.md`), whose tier-up policy, step routines, frames, and fast paths it shares.

## What the backend shares with the native tiers

Everything above the instruction set is the same as on aarch64 and x86-64. The interpreter counts calls and loop iterations in its `warm` loop, a function that reaches its threshold compiles, and the interpreter hands its frame over at an instruction boundary. Compiled code keeps no Lus value in a WebAssembly local across instructions. Registers stay on the Lus stack and frames stay in the frame list, so every instruction boundary is an entry and an exit, and the collector, tracebacks, coroutines, and exception tables read the same frames whatever runs them.

Every instruction is either an inline fast path or a call to the step routine of its opcode, which is the interpreter's own body for it (`jit.md`). A fast path that does not apply runs the step routine of the same instruction from the start. The fast paths read tables, inline cache entries, and frames through `table.layout`, `interp.layout`, and `@offsetOf`, as the native templates do, so a field that moves takes the WebAssembly code with it. The offsets are those of wasm32, where pointers and lengths are 32 bits wide.

| Instructions | Compiled code |
|---|---|
| `move`, `loadk`, `loadi`, `loadf`, `loadnil`, `loadtrue`, `loadfalse`, `not` | Inline. |
| `getupval`, `setupval` | Inline, with the barrier bit tested inline and its slow part called. |
| `add`, `sub`, `mul`, `div` and their constant forms, `addi`, `unm` | Integers and floats inline, anything else in the step routine. |
| `mod`, `idiv` and their constant forms | Integers inline with the rounding of `ops.imod` and `ops.idiv`. |
| `band`, `bor`, `bxor` | Integers inline. |
| `eq`, `lt`, `le`, `lti`, `lei`, `gti`, `gei`, `eqk`, `test`, `testset`, `testnil` | Integers and floats inline and fused with the jump that follows. |
| `jmp`, `forloop`, `tforloop` | Inline. A backward `jmp` first tests for pending finalizers. |
| `getfield`, `gettabup`, `setfield`, `settabup`, `self` | The slot prediction of the inline cache, tested and followed inline. A miss calls the fast path of the interpreter through a helper. |
| `gettable`, `settable`, `getindex` | An integer key inside the array part inline, for every element kind. A string key takes the inline cache through a helper. |
| `len` | The character count of a string inline. A table takes a helper. |
| `call` | The call function of the module (below). |
| `ret0`, `ret1` | Inline when the frame returns to the code that called it. |
| Everything else | The step routine. |

## One module per function

Each compiled function is one module with one exported function, `f(l, stop, pc) -> status`, which runs the frame of the function from instruction `pc` until it leaves. The module imports the memory of the runtime, its function table, and each runtime function it calls.

Batching several functions into one module would share the fixed cost of a module among them. That cost is small. A module of a typical function is 1 to 8 KiB, and Node compiles it in about 0.1 ms and instantiates it in about 0.05 to 0.1 ms. A program that compiles 1000 small functions on their first call spends about 0.1 s in the JIT altogether, which includes emitting the modules inside `lus.wasm` and the first execution of each function, so instantiation is a quarter of the cost at most. Programs under the default threshold compile a few dozen functions. One module per function keeps a function independent of every other: it compiles the moment it is hot, and its code is released when the collector frees the function.

## Getting compiled code to the host

The runtime hands a module to the host through a compile function, `compile(ptr, len, reuse) -> index`. The host reads the module bytes at `ptr`, compiles and instantiates them, installs the exported function in the function table of the runtime, and returns its table index. Zero means that the host could not compile the module, and the function stays interpreted. A nonzero `reuse` is the slot of a function the collector freed, which the host fills instead of growing the table.

The host registers the compile function with `lus_wasm_jit_host(index)`, where `index` is the table entry that holds it. A WebAssembly import must be satisfied when the module is instantiated, so a JIT import would make `lus.wasm` unusable under a runner that does not provide it. Registration keeps the import list of `lus.wasm` to WASI alone. A host that never registers, such as wasmtime or any plain WASI runner, gets a runtime whose JIT setting reads `off` and which runs the `fast` interpreter loop.

The table accepts only WebAssembly functions, so the host passes its JavaScript function through a bridge: a module of a few dozen bytes that imports the function and exports it again. The export is a WebAssembly function, and `table.grow` installs it.

The build links `lus.wasm` with `--export-table` and `--growable-table`. The host installs compiled functions with `table.grow`, and the runtime calls them by index, since a function pointer on wasm32 is a table index.

### Synchronous and background compilation

Modules up to 4 MiB compile synchronously with `new WebAssembly.Module` and `new WebAssembly.Instance`. The longest function the runtime compiles, 30 000 instructions, makes a module of about 5 MiB. A larger module, or one that the engine refuses to compile synchronously, which some browsers do on their main thread, compiles in the background with `WebAssembly.compile`. The host then answers that the module is pending, and the function keeps running in the interpreter. It asks again after sixteen times its threshold of further events, the runtime emits the same bytes again, and the host finds the finished module by its bytes and installs it.

A Lus program runs synchronously inside one call into `lus.wasm`, so a background compilation finishes only after that call returns. It pays off in a long-lived state, such as the language server in the editor or a playground session, whose functions run again on later requests.

## Sharing the step routines

Native code calls a step routine by its address. On wasm32 the address of a function is its index in the function table, so the runtime already has a number for every step routine and helper that compiled code calls. A module imports each one it uses from the module `t` under the decimal string of its index, and the host resolves the import with `table.get`. The engine calls an imported WebAssembly function directly, without a JavaScript transition. The signatures that the module declares for its imports are checked against the real functions when the host instantiates it, so a signature that drifts fails the instantiation and the function stays interpreted.

## Control flow

WebAssembly has structured control flow, so the body of `f` is a loop around a `br_table` with one case per instruction. Each case is a block that ends right before the code of its instruction, so the code of one instruction falls through into the next at no cost. A forward jump is a branch to the end of the block of its target. A backward jump sets the pc and branches to the head of the loop, which dispatches through the `br_table`.

Every instruction is a case, because the interpreter hands frames over at any instruction boundary: on-stack replacement at a loop header, the continuation after a call, and an exception handler. A dispatcher over basic blocks alone would need each of those points to be a block leader, which is every instruction after a call or a step routine. A relooper or a stackifier would make loops into direct branches. The `loop` benchmark already runs 2.4 times faster with the dispatcher, and its loop costs one indirect branch per iteration, so a structuring pass is left until a measurement shows that the dispatch matters.

A step routine reports how execution continues, as in the native tiers. "next" falls through to the following instruction and "skip" branches over it. Any other status reaches the status handler of the function, which sits inside the loop. A step that changed the pc of the same frame of the same function continues from the frame's saved pc in the same activation. Anything else returns the status to the caller of `f`.

## Calls and returns

The trampoline in `jit/wasm.zig` runs compiled frames. It calls the code of the top frame, and when that code returns "dispatch" it looks at the top frame again. A frame whose function has no code yet counts a call and may compile, and a frame that cannot run compiled goes back to the interpreter.

A `call` goes to the call function of its module, a second function that every module with a call has. For a Lus function with fixed parameters and compiled code, called with room for its frame, it pushes the frame as `interp.enterLus` does and calls the code of the callee through `call_indirect`, with the frame count of the caller as its stop. A `ret0` or `ret1` of a frame whose caller is that stop returns inline: it stores the result at the return slot, pops the frame, and reports "done", so the callee returns straight into the call function, which restores the register window of the caller and continues at the next instruction. A tail call replaces the frame of the callee, and the call function runs the code of the new function in the same loop. Anything else, such as a native function, a vararg function, a function without code, or a frame list or stack that must grow, goes to `callFromCode` in the runtime, which runs the native helper or the step routine of `call` and then the same loop.

Calls nest on the WebAssembly stack in this way at most 100 deep, counted across every activation, so a native function that calls back into Lus does not multiply the depth. A deeper call returns "dispatch" and the trampoline runs it. Recursion of any depth therefore works, and only the first 100 levels take the short path.

## Fallback

- A host without a compile function keeps every state interpreted. `debug.jit()` reports `off`.
- A module that fails to compile or instantiate declines its function, which then stays interpreted. The host reports the error to its `onError` option.
- `LUS_JIT` and `LUS_JIT_THRESHOLD` in the environment the host gives `lus.wasm` set the policy, as on native targets, and `jit: false` in the options of `Lus.load` leaves the host without a compile function.
- Hooks, `lus debug`, and every other case the native tiers leave to the interpreter work the same way here.

## Measurements

Wall times in seconds of `packages/wasm/bench/run.mjs`, best of five runs that alternate between the configurations, on Node 22 on an Apple silicon Mac, with the ReleaseSafe `lus.wasm` that the site ships. "off" runs with `LUS_JIT=off`, and "jit" with the default setting. The times include everything the JIT costs: emitting the modules in `lus.wasm`, compiling and instantiating them in the host, and the engine compiling them on their first call. The last columns give, for one run of each benchmark, the modules the JIT made, their size, and the milliseconds the host spent compiling and instantiating them.

| benchmark | off | jit | speedup | modules | KiB | compile ms | instantiate ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| arrays | 0.771 | 0.376 | 2.05 | 1 | 4 | 0.13 | 0.12 |
| closures | 0.235 | 0.216 | 1.09 | 3 | 4 | 0.56 | 0.23 |
| data | 0.073 | 0.071 | 1.03 | 1 | 5 | 0.12 | 0.08 |
| fib | 0.153 | 0.086 | 1.78 | 1 | 2 | 0.10 | 0.08 |
| gcpause | 0.496 | 0.472 | 1.05 | 2 | 7 | 0.19 | 0.15 |
| interp | 2.037 | 1.871 | 1.09 | 1 | 4 | 0.12 | 0.09 |
| loop | 0.836 | 0.344 | 2.43 | 1 | 2 | 0.12 | 0.08 |
| methods | 0.697 | 0.673 | 1.04 | 3 | 7 | 0.25 | 0.13 |
| patterns | 0.426 | 0.424 | 1.01 | 1 | 8 | 0.13 | 0.09 |
| strings | 0.307 | 0.307 | 1.00 | 1 | 4 | 0.22 | 0.08 |
| tables | 0.311 | 0.289 | 1.08 | 1 | 4 | 0.12 | 0.08 |
| unicode | 0.208 | 0.202 | 1.03 | 1 | 3 | 0.12 | 0.08 |

Every benchmark runs at least as fast with the JIT as without it, and the cost of the modules themselves is below a millisecond in every row. The rows that spend their time in Lus code gain the most: `loop` runs 2.4 times faster, `arrays` 2.0 times, and `fib` 1.8 times. The interpreter of the WebAssembly build runs these loops about four times slower than the native interpreter (0.836 s for `loop` against 0.220 s in `jit.md`), and compiled code removes its dispatch from every instruction that runs inline. `methods`, `closures`, and `tables` gain less, because their time goes to allocation, to the collector, and to the step routines of `newtable`, `closure`, and `tailcall`. The rows that measure the runtime underneath, `data`, `interp`, `patterns`, `strings`, and `unicode`, run the same in both columns within the noise.

The first version of the backend sent every call through the step routine of `call` and the trampoline. It made `fib` 1.6 times slower and `closures` 1.9 times slower than the interpreter. Pushing the frame in the call function, running the callee on the WebAssembly stack, and returning inline turned both around.

The backend, the `warm` interpreter loop, and the step routines make `lus.wasm` 420 KB larger, 5.0 MB in place of 4.6 MB.

## Testing

`packages/wasm/test/jit.test.js` runs under `node --test`. It compiles hot functions, runs programs that take every kind of fallback (floats, strings, metamethods, errors, cache misses, array misses, deep recursion, coroutines, finalizers, `__close`, and hooks) with the JIT off, on, and eager and compares their output, and covers a host without the JIT, a host that declines or fails to compile, background compilation, and the reuse of table slots.

`packages/wasm/scripts/conformance.mjs` runs the conformance suite and the language server tests through `lus.wasm` with the JIT off, on, and eager, and fails when the modes disagree on any test. All three modes pass the same 4867 tests of 92 files. The tests that fail under WebAssembly in every mode need the network, workers, processes, or a real file system, and four files (`builtins_parity_test`, `pack_test`, `strings_test`, and `syntax_limits_test`) stop with a trap of the WebAssembly build in every mode, as they do in the build without this backend.

## Open ends

- A module of 30 000 instructions is about 5 MiB, about 160 bytes for each instruction. Shorter templates for the table accesses and a shared exit sequence would shrink it.
- `self` follows `__index` through a helper. The native templates follow two more predictions inline.
- A constructor that adds a key takes the `setStr` helper. The native templates add it inline.
- `tforcall` of a Lus iterator and `tailcall` run their step routines.
- A relooper for loops, if a measurement shows the dispatch at the loop head.
- The tier is measured on Node. Browsers run the same modules, and the playground runs in a worker, where any module compiles synchronously.
