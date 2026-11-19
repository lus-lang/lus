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
- `src/vm`: values, objects, strings (WTF-8), tables, the collector, the interpreter, generic operations (`ops.zig`), debug information, pledge.
- `src/jit/opt`: the optimizing tier. `opt.zig` holds its policy, the exits, and the routines optimized code calls, `flow.zig` the bytecode analysis, `lower.zig` the builder of the intermediate representation in `ir.zig`, `passes.zig` the passes, `regalloc.zig` the register allocator, and `codegen.zig` the code generator for both targets.
- `src/jit`: the baseline JIT. `jit.zig` holds the tier-up policy and the hand-over between the tiers, `emit.zig` the templates, `a64.zig` and `x64.zig` the assemblers, `helpers.zig` the routines native code calls, and `mem.zig` the executable memory. `wasm.zig` is the backend of the WebAssembly build, which emits a WebAssembly module per function.
- `src/lib`: the standard library, one file per module, opened from `lib/init.zig`.
- `src/tools`: `lus test` and the other developer tools, including `lus compile`, which writes a script as a binary chunk.
- `src/api.zig`: the embedding interface used from Zig. `src/capi.zig`: the C interface declared in `include/lus.h`. `src/main.zig`: the CLI. `src/wasm.zig`: the root of the WebAssembly build, which exports the C interface.
- `src/bundle.zig`: the payload format of standalone executables made by `lus build` (`src/tools/build.zig`).

## Writing a native function

A native is `fn (l: *Thread) Error!u32`. Its arguments are `l.arg(1)` through `l.arg(l.argCount())`. It pushes its results with `l.push` and returns how many it pushed. The helpers in `lib/aux.zig` check arguments and format every "bad argument" error, so always use them (`checkInt`, `checkString`, `checkBytes`, `optInt`, `checkTable`, `argError`, `typeError`, `ret`, `retStr`, `retFail`, `newLib`, `setField`).

Errors are raised with `l.raiseFmt`, which prefixes the position of the calling Lus code, or with `l.raise(value)` for an arbitrary error value. A native that calls back into Lus uses `ops.call1` or `ops.callN`.

Every heap allocation can trigger a collection. A freshly created object is safe while nothing else is allocated, so keep new objects reachable (push them on the stack, or store them into a rooted table) before allocating again.

## Strings and bytes

Strings are well-formed WTF-8 and every string function counts characters (`spec/design/strings.md`). Create strings with `l.newString` (validates) or `state.newStringKnown` (for bytes already known to be valid). Raw bytes live in vectors (`lib/vector.zig`: `newVector`, `checkVector`). The single UTF-8 codec is `vm/wtf8.zig`. Do not write another one.

## Permissions

Operations with side effects check a capability through `vm/pledge.zig`: `pledge.require(l, "fs:read", path)` raises the standard error, and `pledge.allowed` returns a boolean. New capabilities are declared with `pledge.define`. C extensions use the same registry through `lus_defcapability`, `lus_require`, and `lus_allowed`.

## The C interface

C functions never see a Zig error. Every exported function that can fail returns a status and leaves the error value on the stack, and a C function raises by returning `LUS_ERROR` after `lus_error`. A C function is a native whose first upvalue holds the C pointer (`trampoline` in `capi.zig`), so its stack frame is an ordinary native frame.

## Conventions

- One implementation per behavior. Reuse `ops.zig` for coercions and formatting, `pack.zig` for binary layouts, `pledge.zig` for permissions.
- Match the semantics and error messages of the legacy C runtime in `../legacy/lus/src` and of the specification in `../spec/stdlib`, unless a design note in `../spec/design` changes them.
- Prose and comments follow the repository rules in `../AGENTS.md`: full sentences, no em or en dashes, no semicolons.
- Tests for a module are Lus files run with `lus test` or plain scripts run with `lus`. Run the legacy corpus from a scratch copy of `../legacy/lus-tests`, never from the repository, because some tests write files.

## The JIT

Hot functions compile to native code on aarch64 and x86-64 (`../spec/design/jit.md`). `-Djit=false` builds without it. At run time `LUS_JIT=off` interprets everything, `LUS_JIT=eager` compiles every function on its first call, and `LUS_JIT_THRESHOLD=N` sets how many calls and loop iterations a function sees before it compiles. `debug.jit()` reports the setting.

Native code calls the interpreter's own body of an opcode for everything it does not run inline, so a change to an opcode in `vm/interp.zig` reaches both tiers. A change to a fast path in `jit/emit.zig` must keep the interpreter's results exactly. Run the conformance suite with `LUS_JIT=eager` after either kind of change, and on x86-64 as well (a cross-built `x86_64-macos` binary runs under Rosetta).

Code that stays hot in baseline code compiles again in the optimizing tier (`../spec/design/opt.md`), which predicts types, keeps values in machine registers, and leaves through guards. `LUS_JIT=baseline` turns that tier off, `LUS_JIT=opt-eager` sends every function through both tiers on its first call, and `LUS_JIT_DUMP=1` prints what it builds. The tier embeds the baseline templates for the instructions it does not type, so a change in `jit/emit.zig` reaches it. It also reads tables and frames directly, through the same layout names as the baseline code, and it repeats what `table.storeStr` and `table.hashSizeExact` decide when it fills a new table, so a change to how constructors size or fill hash parts needs the matching change in `jit/opt/lower.zig` and in `opt.rt`. A new opcode needs an entry in `flow.effects`, which says what it reads and writes. After a change to the tier or to anything it mirrors, run the conformance suite with `LUS_JIT=opt-eager`, natively, on x86-64, and in a `-Dgc-stress=97 -Dgc-verify=true` build.

Optimized code calls optimized code directly when the callee needs no frame while it runs (`../spec/design/opt.md`, "Direct calls"). Such a call pushes no frame, and `opt.unwind` builds the frames of a whole chain of them from the native stack when optimized code is left. It repeats what `interp.enterLus` writes into a frame and the room it asks for, so a change to either needs the matching change there, in the two thunks of `jit/opt/codegen.zig`, and in the frame that the `call` instruction of the interpreter pushes (`interp.enterPlain`). `LUS_JIT_DIRECT=1024` gives a chain 1024 bytes of native stack, which ends every chain after a few activations. Run the conformance suite that way, with `opt-eager` and with the default setting, after a change to any of them.

The WebAssembly build compiles hot functions to WebAssembly modules that the JavaScript host in `../packages/wasm` instantiates (`../spec/design/wasmjit.md`). Its templates in `jit/wasm.zig` mirror the inline paths of `jit/emit.zig`, so a change to a fast path needs the matching change in both. After a change to either, rebuild with `zig build wasm`, copy the module to `../packages/wasm/dist`, and run `node --test` and `node scripts/conformance.mjs` there. The script runs the conformance suite through `lus.wasm` with the JIT off, on, and eager and fails when the modes disagree.

Native code reads tables, inline cache entries, and frames directly. Every offset and constant it uses comes from `table.layout` in `vm/table.zig`, `interp.layout` in `vm/interp.zig`, or `@offsetOf` on `state.Frame`, so a field that moves takes native code with it, and a change that breaks an assumption of the templates fails a compile-time assertion next to those declarations. A change to what the interpreter's fast paths do (`interp.fast`, `lookupIc`, `indexChain`, `table.storeStr`, `table.arrayStoreFast`) needs the matching change in the inline paths of `jit/emit.zig`. Run a `-Dgc-stress=97 -Dgc-verify=true` build over the conformance suite with `LUS_JIT=eager` after touching a store, because the verifier finds a missing barrier.

## Fuzzing

`src/fuzz.zig` holds fuzz targets for the lexer, the parser, the compiler, formatter idempotence, and the binary chunk loader. `zig build test` runs each target once over its seed corpus. `mise run fuzz` (or `zig build test --fuzz=1M`) mutates inputs for a million iterations, and `zig build test --fuzz` alone runs until stopped and serves a coverage view in the browser. A crashing input is saved under `.zig-cache/f/crash`.

