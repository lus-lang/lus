# Testing the runtime

This note describes how the Lus runtime is tested, what it borrows from the testing of SQLite, and the order in which the parts are built. Its goal is a runtime that a reader can trust with any program: every tier computes the same result, every allocation failure ends in a clean error, and every parser of untrusted text survives any input.

## What exists

The runtime has five layers of tests today.

1. **Conformance.** About 6,200 tests in 106 files under `tests/conformance`, run by `lus test`. Each file runs in its own process and its own temporary directory. CI runs the suite with `LUS_JIT=off`, with the default setting, with `LUS_JIT=eager`, and with `LUS_JIT=opt-eager`, on Linux, macOS, and Windows. The language server tests run alongside them.
2. **Stress builds.** `-Dgc-stress=97` collects at almost every allocation point, and `-Dgc-verify=true` checks the tri-color invariant and the write barriers after every mark. The guide in `runtime/HACKING.md` asks for a run of that build after a change to the heap, a store, or the JIT. CI does not run it.
3. **Fuzzing.** `runtime/src/fuzz.zig` holds five targets: the lexer, the parser, the compiler, formatter idempotence, and the loader of binary chunks. `zig build test` runs each target once over 18 seed programs. `mise run fuzz` mutates them for a million iterations. No target runs a program, and none reaches the standard library.
4. **WebAssembly.** `packages/wasm/scripts/conformance.mjs` runs the conformance suite through `lus.wasm` with the JIT off and eager and fails when the two disagree.
5. **Tools and embedding.** The C embedding tests in `tests/embed`, fixture tests for `lus build`, `lus check`, `lus doc`, and `lus debug`, and `lus test --doc` over the manual, the specification, and the agent skills.

Every test above is written by hand, except the fuzz inputs. A hand-written test checks what its author thought of. The bugs that the manual rewrite and the speed work found in the last month (a `having` alias that resolved to an outer variable, an integer overflow in `timecore.zig` reachable from Lus, `range` loops that never ended, a lost worker message) were each a combination of two features that no test combined.

## What SQLite does

SQLite is tested by several independent harnesses, and its developers report about 590 times as much test code as library code. The methods that matter here are these.

- **Many independent oracles.** TH3 runs the same tests on every platform and configuration. The SQL Logic Test runs millions of queries against SQLite and other engines and compares the answers. A disagreement between two implementations is a bug in one of them, and nobody has to write down the expected result.
- **Anomaly testing.** A wrapper around the allocator fails the Nth allocation. A test runs once to count its allocations, then once for each N, and checks that every run ends with `SQLITE_NOMEM`, frees what it allocated, and leaves the database intact. The same is done for I/O: a virtual file system fails the Nth read, write, or sync, and simulates a crash at every point of a transaction.
- **Fuzzing with grammar.** Random SQL from a grammar finds bugs in the planner that byte mutation never reaches, and dbsqlfuzz mutates the SQL and the database file together. Every crashing input becomes a test case.
- **Coverage as a gate.** SQLite reaches 100% branch coverage with TH3, measured on the shipped build. A branch that no test takes is either a missing test or dead code.
- **Assertions and sanitizers.** Thousands of `assert` statements stay in debug builds, and the tests run under Valgrind, the address sanitizer, and the undefined behavior sanitizer.
- **Regression discipline.** Every bug gets a test before its fix, and the test stays forever.

## The plan

The parts below are listed in the order of the bugs we expect them to find. Each part has a quick version that gates every change and a long version that runs every night.

### 1. Differential testing across tiers

The runtime runs one program in seven ways: the interpreter, the baseline JIT that compiles a function on its first call, the baseline JIT that compiles after a few calls, the optimizing tier on the first call, the optimizing tier after a few calls, the WebAssembly build, and the gc-stress build. These seven must agree on the output of every program and on every error it raises. That agreement is an oracle that needs no expected output, the same oracle as the SQL Logic Test.

The generator lives in `tests/diff` and is written in JavaScript, so that a bug in the runtime cannot hide a bug in its own test. It builds programs from a typed model of the language. Each expression it emits has a known type, so most programs run to the end instead of stopping at the first type error. It composes the features that interact: closures and upvalues, varargs and multiple returns, `catch` with and without handlers, `<close>` variables across yields and errors, coroutines and detached coroutines, metamethods on tables, enums, groups, do-expressions, `continue`, slices, string interpolation, optional chaining, queries over tables, integer overflow, float edge cases, bigints and decimals, and string functions on WTF-8 text. Loops run long enough to cross the JIT thresholds in the middle, which exercises the hand-over between the tiers.

A program prints a trace of the values it computes. The trace leaves out what the language leaves open: table addresses and the order of `pairs`. An error is printed by its message, which includes the line, so the tiers must also agree on positions.

A run that disagrees, crashes, or hangs goes to the reducer, which deletes statements, blocks, and expressions while the disagreement stays, in the manner of delta debugging. The small program it ends with goes into `tests/conformance/diff_regress_test.lus` once the bug is fixed.

`mise run diff` runs 300 programs as a gate. `mise run diff:long` runs until stopped and saves every finding under `tests/diff/findings`.

### 2. Deeper fuzzing

The fuzz targets in `runtime/src/fuzz.zig` grow to the code that reads untrusted text at run time: `fromjson` and `tojson`, `fromcsv` and `tocsv`, pattern matching, `string.format`, `time.parse`, the parsers of bigint and decimal literals and of `tonumber`, `string.pack` and `string.unpack`, and the archive codecs. Each target checks a property and not only the absence of a crash. A JSON value that `fromjson` accepts must survive a round trip through `tojson`, and a pattern that compiles must match without a fault. A target for the compiler runs the compiled chunk as well, with an instruction limit. The seed corpus lives in the repository under `runtime/fuzz/corpus`, one directory per target, and every crash becomes a seed.

### 3. Out of memory injection

A build option `-Dfail-alloc=true` adds a countdown to the counting allocator that every state allocates through, and to the allocation of heap pages. `LUS_FAIL_ALLOC=N` makes the Nth allocation fail and every later one succeed. A runner counts the allocations of a test file, then runs the file with each N in a sweep and checks four things: the process does not crash or panic, the error it reports is "not enough memory" or a clean test failure, the leak checker of the safe build reports nothing, and a gc-verify build finds the heap consistent. The quick version samples 50 values of N over a few files, and the long version sweeps every N over the whole suite.

### 4. I/O fault injection

The same build option adds a countdown to the system calls under `fs`, `io`, the sockets, and the SQLite file layer. `LUS_FAIL_IO=N:kind` turns the Nth call into a short read or write, `ENOSPC`, `EINTR`, a reset connection, or a timeout. The runner checks that each fault reaches Lus code as an error that names the operation, that a short read or write is retried, and that nothing leaks or hangs.

### 5. Coverage

A build with coverage instrumentation runs the conformance suite and reports branch coverage of `src/vm`, `src/compile`, `src/jit`, and `src/syntax` as one number per directory. The number is published by the nightly job. Uncovered branches in the interpreter, the collector, and the compiler get tests first, since they run in every program.

### 6. Properties and metamorphic tests

Some results have an oracle other than another tier. These tests live in `tests/conformance/props_test.lus` and draw their inputs from a seeded generator, so a failure prints the seed that reproduces it.

- Bigint and decimal arithmetic agree with a reference written in JavaScript on random operands.
- `fromjson(tojson(v))` and `fromcsv(tocsv(rows))` return a value equal to `v` and `rows`.
- Random WTF-8 strings keep the string invariants: `#s` equals the count of `utf8.codes`, `s:sub(i, j) .. s:sub(j + 1)` equals `s:sub(i)`, and slices agree with `string.sub`.
- A query returns the same rows as a hand-written loop over the same table, and the same rows from a table source as from SQLite.
- `lus fmt` is idempotent and keeps the meaning of a program: a generated program prints the same trace before and after formatting.

### 7. Sanitizers and stress in CI

The nightly job runs the conformance suite in a `-Dgc-stress=1 -Dgc-verify=true` build, which collects at every allocation, and the differential and fuzzing long runs. The vendored C libraries (SQLite, Zstandard, and Brotli) build with the address and undefined behavior sanitizers in a separate job.

## Gates and findings

Every bug found gets a regression test in `tests/conformance` before its fix. A bug left open is recorded in `tests/diff/OPEN.md` with its smallest reproducer, so the next person to touch that code finds it.

The quick versions run in `mise run test` and in CI on every change: 300 differential programs, every fuzz target over its corpus, and a sample of the allocation sweep. The long versions run in a nightly workflow, `.github/workflows/nightly.yml`.
