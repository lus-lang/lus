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
- `src/compile`: code generator, bytecode format, disassembler.
- `src/vm`: values, objects, strings (WTF-8), tables, the collector, the interpreter, generic operations (`ops.zig`), debug information, pledge.
- `src/lib`: the standard library, one file per module, opened from `lib/init.zig`.
- `src/tools`: `lus test` and the other developer tools.
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

## Fuzzing

`src/fuzz.zig` holds fuzz targets for the lexer, the parser, the compiler, formatter idempotence, and the binary chunk loader. `zig build test` runs each target once over its seed corpus. `mise run fuzz` (or `zig build test --fuzz=1M`) mutates inputs for a million iterations, and `zig build test --fuzz` alone runs until stopped and serves a coverage view in the browser. A crashing input is saved under `.zig-cache/f/crash`.

