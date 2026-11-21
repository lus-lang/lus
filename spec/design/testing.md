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

The runtime runs one program in many ways: the interpreter, the default tiering, the baseline JIT that compiles a function on its first call, the baseline JIT that compiles after two calls, the optimizing tier on the first call, the optimizing tier after three calls, the optimizing tier with short chains of direct calls, the gc-stress build under both JIT tiers, the x86-64 build, whose JIT is a second backend, and the WebAssembly build with its JIT off, on, and eager, which is a third. These configurations must agree on the output of every program and on every error it raises. That agreement is an oracle that needs no expected output, the same oracle as the SQL Logic Test. Each configuration compares with the interpreter of its own architecture, since arm64 and x86-64 differ in their math libraries and in the sign of a NaN, and the WebAssembly host reports errors without a traceback. One more configuration formats the program with `lus fmt` first, which must keep its meaning.

The generator, the runner, and the reducer live in `tests/diff` and are written in Lus, so they exercise Lus too. A bug of the runtime must not hide a bug in its own test, so the three run interpreted with `LUS_JIT=off`, the generator writes each program to a file, and every configuration runs that file in a fresh process. A program therefore depends on the generator's run only through its text, and the configurations under test never share a process with the code that judges them. The WebAssembly build runs in Node through a small host script, `tests/diff/wasm.mjs`. The generator builds programs from a typed model of the language. Each expression it emits has a known type, so most programs run to the end instead of stopping at the first type error. It composes the features that interact: closures and upvalues, varargs and multiple returns, `catch` with and without handlers, `<close>` variables across yields and errors, coroutines and detached coroutines, metamethods on tables, enums, groups, do-expressions, `continue`, slices, string interpolation, optional chaining, queries over tables, integer overflow, float edge cases, bigints and decimals, and string functions on WTF-8 text. The body of a program is a few units, each a function called up to 160 times from a loop whose arguments change type partway, from integers to floats, numeric strings, or values near the edges of the integer range. Code compiled for one type then meets another and leaves through its guards. Other statements change the element kind of an array in the middle of a loop, read tables of several shapes through one site, compare integers and floats near 2^53 and 2^63, and run numeric loops at the ends of the integer range.

A program prints a trace of the values it computes. The trace leaves out what the language leaves open: table addresses and the order of `pairs`. An error is printed by its message, which includes the line, so the tiers must also agree on positions.

A run that disagrees, crashes, or hangs goes to the reducer, which reads the program as a tree of lines by indentation and deletes statements, unwraps blocks, and replaces parenthesized expressions with literals while the disagreement stays, in the manner of hierarchical delta debugging. It took the first finding from 230 lines to 21 in three seconds. The small program it ends with goes into `tests/conformance/diff_regress_test.lus` once the bug is fixed, or into `tests/diff/OPEN.md` while it is open.

`mise run diff` runs the same 200 programs on every change. `mise run diff:long` runs fresh seeds until stopped, and the nightly job runs it for 80 minutes on Linux and macOS.

The first 7,000 programs found two bugs. A `__close` handler that raised while `catch` unwound could move the frame list under the handler, which then wrote through a stale pointer. The optimizing tier lost one call of a closure that incremented an upvalue in a loop, because its common subexpression key left out the memory class, so a load of a captured register stood in for a later load of the same slot. Both are fixed with regression tests.

### 2. Deeper fuzzing

The fuzz targets in `runtime/src/fuzzlib.zig` reach the code that reads untrusted text at run time: `fromjson` and `tojson`, `fromcsv` and `tocsv`, pattern matching, `string.format`, `time.parse`, `tonumber`, `bigint`, and `decimal`, `string.pack`, `string.unpack`, and their vector forms, every archive codec, and the string functions on arbitrary text. Each target runs a property written in Lus over the input, so it checks behavior and not only the absence of a crash. JSON and CSV that parse must format to text that parses to the same value, a number must print to text that reads back as the same number, `string.gsub(s, p, "%0")` must return `s` for any valid pattern, and each codec must decompress its own output. The seeds live next to each target, and every crash becomes a seed.

The JSON target found that an array with a `null` element formats as `{}`, which follows the specification of both functions but loses data (`tests/diff/OPEN.md`).

### 3. Out of memory injection

A build option `-Dfail-alloc=true` numbers every allocation of every state and every heap segment. `LUS_FAIL_ALLOC=N` makes the Nth allocation fail and every later one succeed, `N+` makes every allocation from the Nth on fail, and `count` prints how many allocations a run made. `tests/oom/run.lus`, which also runs interpreted in a normal build, counts the allocations of each conformance file, then runs the file once for each sampled N and checks three things: the process does not crash or panic, the leak checker of the safe build reports nothing, and the run ends in bounded time. A test may fail and a run may end with "not enough memory". Each distinct failure is reported once, with the smallest N that produced it. `mise run oom` samples 8 values of N per file on every change, and the nightly job samples 400, then 100 with every later allocation failing too.

The first sweeps found nine bugs, all fixed: panics in `print` and in the permission registry, an index below the stack in a worker whose script failed to compile for lack of memory, a panic while canonicalizing a path permission, and leaks in `-F` flags, `pledge`, and the copy of a permission set for a worker.

### 4. I/O fault injection

The same build option adds a countdown to the system calls under `fs`, `io`, the sockets, and the SQLite file layer. `LUS_FAIL_IO=N:kind` turns the Nth call into a short read or write, `ENOSPC`, `EINTR`, a reset connection, or a timeout. The runner checks that each fault reaches Lus code as an error that names the operation, that a short read or write is retried, and that nothing leaks or hangs.

### 5. Coverage

A build with coverage instrumentation runs the conformance suite and reports branch coverage of `src/vm`, `src/compile`, `src/jit`, and `src/syntax` as one number per directory. The number is published by the nightly job. Uncovered branches in the interpreter, the collector, and the compiler get tests first, since they run in every program.

### 6. Properties and metamorphic tests

Some results have an oracle other than another tier. These tests live in `tests/conformance/props_test.lus` and draw their inputs from a seeded generator, so a failure prints the seed that reproduces it.

- Integer, bigint, and decimal arithmetic agree on random operands where all three are exact, bigints agree with decimals past 64 bits, and integer arithmetic wraps exactly where bigint arithmetic reduced to 64 bits says it does.
- `fromjson(tojson(v))` and `fromcsv(tocsv(rows))` return a value equal to `v` and `rows`.
- Random WTF-8 strings keep the string invariants: `#s` equals the count of `utf8.codes`, `s:sub(i, j) .. s:sub(j + 1)` equals `s:sub(i)`, and slices agree with `string.sub`.
- A query returns the same rows as a hand-written loop over the same table, and its groups partition the rows.
- `table.sort` agrees with an insertion sort.
- `lus fmt` keeps the meaning of a program, which the `fmt` configuration of the differential tester checks on every generated program.

### 7. Sanitizers and stress in CI

The nightly workflow runs the conformance suite in a `-Dgc-stress=1 -Dgc-verify=true` build, which collects at every allocation, on Linux and macOS with the JIT off, eager, and optimizing. It also runs the long versions of the differential tests, the allocation sweep, and the fuzz targets, and uploads each finding. Building the vendored C libraries (SQLite, Zstandard, and Brotli) with the address and undefined behavior sanitizers comes next.

## Gates and findings

Every bug found gets a regression test in `tests/conformance` before its fix, except bugs of allocation failure, which the sweep itself keeps finding. A bug left open is recorded in `tests/diff/OPEN.md` with its smallest reproducer, so the next person to touch that code finds it.

The quick versions run in CI on every change: 200 differential programs, every fuzz target over its seeds as part of `zig build test`, the property tests as part of the conformance suite, and 8 sampled allocation failures per conformance file. The long versions run in `.github/workflows/nightly.yml`. I/O fault injection and coverage, parts 4 and 5, come after the parts above have run long enough to stop finding bugs.
