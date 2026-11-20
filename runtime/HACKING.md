# Working on the Lus runtime

The runtime is written in Zig 0.17.1. Build it from this directory:

```sh
export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global
zig build -Doptimize=ReleaseSafe        # the lus binary in zig-out/bin
zig build test                          # unit tests
zig build lib                           # liblus.a, the shared liblus, and lus.h
zig build test-embed                    # the C embedding tests in ../tests/embed
zig build test-bundle                   # `lus build` on ../tests/build
zig build test-debug                    # `lus debug` driven by ../tests/debug/run.mjs (needs node)
zig build wasm                          # lus.wasm for wasm32-wasi in zig-out/wasm
```

The libraries that need more than a plain host are optional: `-Dnet`, `-Dworkers`, `-Dsqlite`, and `-Darchive`. All four default to true, except that the WebAssembly build leaves out the network and worker libraries. A library left out is never registered (`src/lib/init.zig`) and its code is compiled out. `../packages/wasm` holds the JavaScript host for `lus.wasm` and explains how to use it.

Debug builds work but run slowly, because the debug allocator records a stack trace for every allocation. Use ReleaseSafe for anything that runs real programs.

## Layout

- `src/syntax`: lexer, syntax tree, parser, tree walker.
- `src/compile`: code generator, bytecode format, disassembler, binary chunks (`dump.zig`).
- `src/vm`: values, objects, strings (WTF-8), tables, the collector, the interpreter, generic operations (`ops.zig`), debug information, pledge, and the scheduler of detached coroutines (`sched.zig`).
- `src/jit/opt`: the optimizing tier. `opt.zig` holds its policy, the exits, and the routines optimized code calls, `flow.zig` the bytecode analysis, `lower.zig` the builder of the intermediate representation in `ir.zig`, `passes.zig` the passes, `regalloc.zig` the register allocator, and `codegen.zig` the code generator for both targets.
- `src/jit`: the baseline JIT. `jit.zig` holds the tier-up policy and the hand-over between the tiers, `emit.zig` the templates, `a64.zig` and `x64.zig` the assemblers, `helpers.zig` the routines native code calls, and `mem.zig` the executable memory. `wasm.zig` is the backend of the WebAssembly build, which emits a WebAssembly module per function.
- `src/lib`: the standard library, one file per module, opened from `lib/init.zig`.
- `src/tools`: `lus test` and the other developer tools, including `lus compile`, which writes a script as a binary chunk.
- `src/api.zig`: the embedding interface used from Zig. `src/capi.zig`: the C interface declared in `include/lus.h`. `src/main.zig`: the CLI. `src/wasm.zig`: the root of the WebAssembly build, which exports the C interface.
- `src/bundle.zig`: the payload format of standalone executables made by `lus build` (`src/tools/build.zig`).

## Writing a native function

A native is `fn (l: *Thread) Error!u32`. Its arguments are `l.arg(1)` through `l.arg(l.argCount())`. It pushes its results with `l.push` and returns how many it pushed. The helpers in `lib/auxlib.zig` check arguments and format every "bad argument" error, so always use them (`checkInt`, `checkString`, `checkBytes`, `optInt`, `checkTable`, `argError`, `typeError`, `ret`, `retStr`, `retFail`, `newLib`, `setField`).

Errors are raised with `l.raiseFmt`, which prefixes the position of the calling Lus code, or with `l.raise(value)` for an arbitrary error value. A native that calls back into Lus uses `ops.call1` or `ops.callN`.

Every heap allocation can trigger a collection. A freshly created object is safe while nothing else is allocated, so keep new objects reachable (push them on the stack, or store them into a rooted table) before allocating again.

## Natives that wait

A native that would block waits through the scheduler (`vm/sched.zig`, `../spec/design/coroutines.md`). It first tries its operation without waiting. When the operation reports that it would block, the native calls `sched.waitIo` with the handle, the direction, and the timeout, and tries again when that returns true. `sched.waitJoin` waits for the end of a detached coroutine, `sched.waitNotify` waits for a `sched.notify` from another thread or a `sched.signal` from this one, and `sched.pass` lets the other coroutines run. A timeout runs from the first `waitIo` of a call, and a native calls `sched.opDone` when its operation made progress, so that the next wait of the same call has a timeout of its own.

Inside a detached coroutine these calls return the error that suspends the thread, with `l.yielding` set. The native passes that error on with `try`, like any other error, and never catches it. The frame of the native stays on the stack, and when the wait is over `interp.restartNative` calls the native again with the same arguments. A native that waits therefore follows three rules.

- It runs from its start again after every wait. What it has done so far lives outside its locals: in the object it works on (the receive buffer of a socket), in `sched.saveProgress` and `sched.progress` (a count, such as the bytes a send already wrote), or in the `ctx` of its scheduler record with a `cancel` routine that releases it when the coroutine is closed (`Connecting` in `lib/network.zig`).
- It pushes nothing that the next run must find gone. The stack top at the wait is the stack top of the next run, so a native may also keep values in its own argument slots across runs, as `serve` does.
- Cleanup that must wait for the real end of the call checks `l.yielding` first, as in `defer if (!l.yielding) release()`.

Anywhere else the same calls keep the native on the stack, run the scheduler until the event arrives, and return. Other coroutines ran in the meantime, so the native checks that the object it waits on is still open before it touches it again (`stillOpen` in `lib/network.zig`). A handle that is about to close goes through `sched.forget` first, which wakes its waiters.

After a change to the scheduler or to a native that waits, run `detach_test.lus`, `netcoro_test.lus`, `serve_test.lus`, `workercoro_test.lus`, and `netcli_test.lus` under every JIT mode and in a `-Dgc-stress=97 -Dgc-verify=true` build, and run the suite on Linux as well, where the poller is epoll.

## Strings and bytes

Strings are well-formed WTF-8 and every string function counts characters (`spec/design/strings.md`). Create strings with `l.newString` (validates) or `state.newStringKnown` (for bytes already known to be valid). Raw bytes live in vectors (`lib/vector.zig`: `newVector`, `checkVector`). The single UTF-8 codec is `vm/wtf8.zig`. Do not write another one.

## Permissions

Operations with side effects check a capability through `vm/pledge.zig`: `pledge.require(l, "fs:read", path)` raises the standard error, and `pledge.allowed` returns a boolean. New capabilities are declared with `pledge.define`. C extensions use the same registry through `lus_defcapability`, `lus_require`, and `lus_allowed`.

## The C interface

C functions never see a Zig error. Every exported function that can fail returns a status and leaves the error value on the stack, and a C function raises by returning `LUS_ERROR` after `lus_error`. A C function is a native whose first upvalue holds the C pointer (`trampoline` in `capi.zig`), so its stack frame is an ordinary native frame.

## Conventions

- One implementation per behavior. Reuse `ops.zig` for coercions and formatting, `pack.zig` for binary layouts, `pledge.zig` for permissions.
- Match the semantics and error messages of the specification in `../spec/stdlib` and of the design notes in `../spec/design`.
- Prose and comments follow the repository rules in `../AGENTS.md`: full sentences, no em or en dashes, no semicolons.
- Tests for a module are Lus files run with `lus test` or plain scripts run with `lus`.

## The interpreter loop

`vm/interp.zig` holds one dispatch loop, instantiated as the plain loop, the loop that counts for the JIT, the hooked loop, and one step routine per opcode (`../spec/design/jit.md`). `../spec/design/interp.md` records how its hot paths are shaped and why. A change there should keep to these rules.

- A frame that the `call` instruction pushes keeps what the stack holds in its registers, apart from the parameters. No instruction may count on a fresh register being nil: an instruction writes a register before it reads it, and the compiler emits `loadnil` for every local that starts nil.
- The stack top of a running Lus frame is its last register plus one between instructions, unless the instruction before left a variable number of values. A call restores it on return, because the frame of a callee can end below the frame of its caller.
- Values go through the hot paths as pointers or as their two words. A 16-byte value that an inline routine returns from two places is built in memory.
- Signed operands are two's complement (`opc.sbx`, `opc.sj`, `opc.sb`, `opc.sc`), and `opc.signedByte` encodes the 8-bit ones.
- `opc.op` gives the plain opcode of an instruction and `opc.code` the opcode it holds, which may be fused. Only the two unhooked loops and the listing read `opc.code`. A new fused pair is an entry in `opc.fusions` and a case in the loop that runs the first body and then the fast path of the second from the definition the plain case uses. `../tests/conformance/fused_test.lus` covers the pairs.

Read the instruction count first when measuring a change to the loop (`LUS_JIT=off /usr/bin/time -l zig-out/bin/lus ../tests/bench/fib.lus` on macOS), since it is exact and the wall time of the loop moves by a few percent with its code layout. `zig build -Dop-profile=true` makes a binary that counts the opcode pairs and runs of three it dispatches and prints them at exit, and `node ../tools/op-ngrams.js <that binary>` ranks them over the bench corpus.

## The JIT

Hot functions compile to native code on aarch64 and x86-64 (`../spec/design/jit.md`). `-Djit=false` builds without it. At run time `LUS_JIT=off` interprets everything, `LUS_JIT=eager` compiles every function on its first call, and `LUS_JIT_THRESHOLD=N` sets how many calls and loop iterations a function sees before it compiles. `debug.jit()` reports the setting.

Native code calls the interpreter's own body of an opcode for everything it does not run inline, so a change to an opcode in `vm/interp.zig` reaches both tiers. A change to a fast path in `jit/emit.zig` must keep the interpreter's results exactly. Run the conformance suite with `LUS_JIT=eager` after either kind of change, and on x86-64 as well (a cross-built `x86_64-macos` binary runs under Rosetta).

Code that stays hot in baseline code compiles again in the optimizing tier (`../spec/design/opt.md`), which predicts types, keeps values in machine registers, and leaves through guards. `LUS_JIT=baseline` turns that tier off, `LUS_JIT=opt-eager` sends every function through both tiers on its first call, and `LUS_JIT_DUMP=1` prints what it builds. The tier embeds the baseline templates for the instructions it does not type, so a change in `jit/emit.zig` reaches it. It also reads tables and frames directly, through the same layout names as the baseline code, and it repeats what `table.storeStr` and `table.hashSizeExact` decide when it fills a new table, so a change to how constructors size or fill hash parts needs the matching change in `jit/opt/lower.zig` and in `opt.rt`. A new opcode needs an entry in `flow.effects`, which says what it reads and writes. After a change to the tier or to anything it mirrors, run the conformance suite with `LUS_JIT=opt-eager`, natively, on x86-64, and in a `-Dgc-stress=97 -Dgc-verify=true` build.

Optimized code calls optimized code directly when the callee needs no frame while it runs (`../spec/design/opt.md`, "Direct calls"). Such a call pushes no frame, and `opt.unwind` builds the frames of a whole chain of them from the native stack when optimized code is left. It repeats what `interp.enterLus` writes into a frame and the room it asks for, so a change to either needs the matching change there, in the two thunks of `jit/opt/codegen.zig`, and in the frame that the `call` instruction of the interpreter pushes (`interp.enterPlain`). `LUS_JIT_DIRECT=1024` gives a chain 1024 bytes of native stack, which ends every chain after a few activations. Run the conformance suite that way, with `opt-eager` and with the default setting, after a change to any of them.

The WebAssembly build compiles hot functions to WebAssembly modules that the JavaScript host in `../packages/wasm` instantiates (`../spec/design/wasmjit.md`). Its templates in `jit/wasm.zig` mirror the inline paths of `jit/emit.zig`, so a change to a fast path needs the matching change in both. After a change to either, rebuild with `zig build wasm`, copy the module to `../packages/wasm/dist`, and run `node --test` and `node scripts/conformance.mjs` there. The script runs the conformance suite through `lus.wasm` with the JIT off, on, and eager and fails when the modes disagree.

Native code reads tables, inline cache entries, and frames directly. Every offset and constant it uses comes from `table.layout` in `vm/table.zig`, `interp.layout` in `vm/interp.zig`, or `@offsetOf` on `state.Frame`, so a field that moves takes native code with it, and a change that breaks an assumption of the templates fails a compile-time assertion next to those declarations. A change to what the interpreter's fast paths do (`interp.fast`, `lookupIc`, `indexChain`, `table.storeStr`, `table.arrayStoreFast`) needs the matching change in the inline paths of `jit/emit.zig`. Run a `-Dgc-stress=97 -Dgc-verify=true` build over the conformance suite with `LUS_JIT=eager` after touching a store, because the verifier finds a missing barrier.

## The collector

Marking runs on several threads on native targets when a collection that stops the program has enough work (`gcpar.zig`, `../spec/design/gc.md`). The parallel marker is the same code as the sequential one, instantiated with atomic marks, so a change to tracing reaches both. `LUS_GC_THREADS=1` marks on one thread. A `-Dgc-stress=97` build drains in parallel at almost every collection, and `-Dsanitize-thread=true` adds ThreadSanitizer. After a change to marking, run the conformance suite several times in a stress build and once in a stress build with ThreadSanitizer. The executable of that build finds the ThreadSanitizer library through `DYLD_LIBRARY_PATH` on macOS, set to the directory under `.zig-cache` that holds it, and the tests that start a fresh `lus` process fail there because the process does not inherit that setting.

## Fuzzing

`src/fuzz.zig` holds fuzz targets for the lexer, the parser, the compiler, formatter idempotence, and the binary chunk loader. `zig build test` runs each target once over its seed corpus. `mise run fuzz` (or `zig build test --fuzz=1M`) mutates inputs for a million iterations, and `zig build test --fuzz` alone runs until stopped and serves a coverage view in the browser. A crashing input is saved under `.zig-cache/f/crash`.

