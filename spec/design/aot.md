# Ahead-of-time compilation

`lus build --aot` writes an executable that holds the machine code of the program, compiled by the two JIT tiers during a training run, next to the binary chunks that `lus build` already bundles. The executable starts with its hot code in place. It also runs on systems that refuse executable memory to ordinary programs, such as iOS and the game consoles, where a JIT cannot run at all. Its runtime leaves out the parser and the compiler, so `load` with source text raises an error there. Lus bundles no Zig compiler for it. The backends of the JIT emit the code, which a prebuilt runtime maps at startup.

## What it is for

The executable serves three cases, in this order of weight.

1. **Targets without a JIT.** iOS, the consoles, and processes under a policy that forbids executable memory run the interpreter today. Code compiled ahead of time is the only way native code reaches them.
2. **Size.** A program that never compiles source at run time needs neither the parser nor the compiler. A program that never reaches a library needs neither that library.
3. **Costly optimizations.** A pass whose compile time a JIT cannot afford can run once at build time. Equality saturation for vectorization, which the speed workstream is building, is the first such pass. It runs only under `--aot`.

Startup and peak speed on systems that have a JIT are not among the reasons. `warmstart.md` measured that a cold start has almost no warmup to save: a function compiles after 60 events, a long loop compiles before its first iteration, and moving the compile to load time saved nothing measurable. Code compiled ahead of time is the code the JIT would compile, so its steady state is the same speed. The measurements below check both statements before the work starts.

## The training run

`lus build --aot` runs the program once under the normal JIT, with the arguments that `--train` names, or runs a training script that `--train-script` names. When the run ends, the builder walks every function of every bundled chunk.

- A function that has optimized code contributes each of its units, as the run compiled them from its own samples and exits.
- A function that has baseline code contributes it.
- A function that never compiled stays bytecode and runs in the interpreter, or compiles at run time where the target has a JIT.

Compiling in the training process keeps every prediction exactly as the JIT made it, so no profile format has to describe types, shapes, call targets, or exits. The builder serializes the code that already exists.

The predictions that name hash nodes depend on the hash seed of the state, which mixes in the address of the state (`warmstart.md`). An executable compiled ahead of time therefore runs with the seed of its training run, which the builder draws fresh for every build and records in the executable. A table that the program builds in the same order then puts its keys in the same nodes, so every node prediction holds. Any other table fails the guard and runs the instruction in the interpreter, which is slower and still correct.

The recorded seed has a cost. Every process of one executable hashes with the same seed, so an attacker who learns it, from the executable or from the timing of one process, can choose keys that collide in every process of that executable. A random seed per process would defend against that and give up the node predictions. Executables that hash keys from untrusted input, such as a server that parses request headers into tables, should take that into account.

## Code objects and relocations

Native code embeds absolute addresses. The emitter writes them with `movImm` and `call`: the routines of the runtime, the global state, the constants and inline cache entries of a function, interned strings, shapes, metatables, and other code. A code object compiled ahead of time replaces each with a relocation that names what the address points to.

| relocation | resolves to |
|---|---|
| routine `n` | the address of entry `n` in a table of the routines that native code calls, in the prebuilt runtime |
| global field `f` | an offset into the global state of the running process |
| constant `k` of function `p` | the address of that constant after the chunk loads |
| inline cache `i` of function `p` | the address of that entry |
| string `s` | the interned string, created at load |
| code `c` at offset `o` | another code object of the same executable |
| shape or metatable `m` | an object that the builder records with its construction, rebuilt at load |

Every address reaches machine code through the `movImm`, `call`, or `storeImm64` of an assembler, so the code generators name no addresses themselves. An assembler that compiles ahead of time hands each immediate wider than 32 bits to a resolver (`jit/aot.zig`), which finds what the address points to: a routine in the table that numbers them (`aot.routines`), a field of the global state or the object that a word of it holds, a field, a constant, or an inline cache entry of a function, the object that a constant holds, a unit, a native function, or an interned string, which it names by its characters. The assembler then writes the address in a form whose bytes the loader patches (`reloc.Form`) and records the relocation. An immediate in the heap or in the image of the executable that the resolver cannot name makes the unit unusable ahead of time. Any other immediate is a literal. When the assembler compiles for the JIT, none of this runs, so its code stays the same byte for byte.

`LUS_JIT_AOT=check:PATH` makes both tiers compile every function in that form, with the real addresses in the patchable words, and run it. Every address that the resolver cannot name appends a line to PATH. Under it the conformance suite, the tests of the language server, and the examples of the documentation pass with an empty log. So the patchable forms run, and every address has a relocation. CI runs that check on macOS.

Speculation on an object that the runtime cannot rebuild by name, such as a table that the program built and a guard compares by identity, makes the builder drop that unit and keep the baseline code of its function.

## The executable

The executable is a prebuilt runtime, built with `-Dcompiler=false`, followed by the payload of `lus build` and a section of code objects with their relocations. The runtime without a compiler leaves out `src/syntax` and `src/compile` except the loader of binary chunks. `load` of source text raises "the compiler is not part of this executable". Prebuilt runtimes ship with each release for every target, as the release binaries do today.

At startup the runtime loads the chunks as `lus build` does, maps the code section, applies the relocations, makes the pages executable, and points each function at its code. On a target without executable memory, the code section lives in the executable image itself, linked at build time against the prebuilt runtime as a static library, which keeps the image signed as one piece. The relocations are then resolved by the system loader.

The runtime leaves out both JIT tiers by default, so code that the training run never reached runs in the interpreter. On a target that allows executable memory, `--aot-keep-jit` keeps them, so that code compiles at run time as it does under `lus build`.

### The runtime without a compiler

`zig build runtime` builds `lus-runtime` with `-Dcompiler=false` and `-Djit=false`, and `lus build --runtime lus-runtime` appends a bundle to it in place of the running `lus`. A reference to the compiler sits behind a check of the build option at compile time, so the compiler, the parser, the formatter, the linter, the tools, and the JIT are never compiled into it. What remains of `src/syntax` and `src/compile` is the reader and the writer of binary chunks and the parser of numbers that `tonumber` uses. Without a bundle the runtime prints that it runs only the bundle appended to it. `load` of source text returns nil and "the compiler is not part of this executable", and `debug.parse`, `debug.format`, and `debug.check` raise that error. Observed variables compile a small chunk when a program first reaches them, so a program that uses them stops with that message on this runtime until the builder bundles the chunk compiled in advance.

On an Apple silicon Mac in ReleaseFast, `lus-runtime` takes 6.37 MB against 8.70 MB for `lus`. A bundle of a benchmark from `tests/bench` takes 6.38 MB against 8.94 MB, and gives the same output. An empty bundle starts in 2.74 ms against 2.75 ms, the best of 150 alternating runs. Until code compiled ahead of time is appended, the runtime interprets, so the benchmarks that native code speeds up run as fast as under `LUS_JIT=off`. `zig build test-runtime` bundles `tests/build/app.lus` on the runtime and checks its output, and checks the message of `load`.

## Leaving out libraries

A library can go only when no path of the program reaches it. The builder proves that from the bytecode, conservatively. A program qualifies when every global access names a constant, `_ENV` is never read as a value, the debug library is not reached, and every `require` names a constant module. The builder then keeps the libraries that those constants name. It leaves out the others by default. When the proof fails, the builder keeps every library and prints the first access that the proof could not name, so the result never depends on a guess.

## Measurements before building

Each part below is built only when its measurement supports it, as `snapshot.md` and `warmstart.md` did for earlier proposals.

1. **Startup.** The time from exec to the first line of output of `lus build` executables for the programs in `tests/bench`, against the same programs with every function compiled at load. This bounds what code in place can save.
2. **Time to steady state.** The time each benchmark spends before its last compilation, from `LUS_JIT_DUMP` timestamps. Ahead-of-time code saves this time, so only programs whose runs are short compared to it gain.
3. **Peak speed.** The benchmarks under the JIT against the same code relocated from a code object. Relocated addresses cost nothing at run time, so the two must agree within the noise of the measurement.
4. **Size.** The executable of `lus build` against one from a runtime built with `-Dcompiler=false`, and against one without the libraries that the proof leaves out, for the programs that qualify.
5. **Targets without a JIT.** The benchmarks in the interpreter against the same programs with code compiled ahead of time, under an executable-memory policy that refuses mappings, which stands in for iOS on macOS.

Measurement 5 decides whether the work happens at all. The others decide which options are worth their code.

### What was measured

The table gives the best wall time of five runs of each benchmark in `tests/bench`, in seconds, from a ReleaseFast build on an Apple silicon Mac. "off" is the interpreter, "on" the default JIT, and "opt-eager" sends every function through both tiers on its first call, which stands in for code that is in place before the first call. Starting the executable with an empty script takes 2.7 ms.

| benchmark | off | on | opt-eager | on over off | opt-eager over on |
|---|---:|---:|---:|---:|---:|
| arrays | 0.216 | 0.035 | 0.044 | 6.2 | 0.80 |
| closures | 0.087 | 0.073 | 0.075 | 1.2 | 0.97 |
| data | 0.035 | 0.029 | 0.031 | 1.2 | 0.92 |
| fib | 0.040 | 0.010 | 0.010 | 3.8 | 1.03 |
| forfrom | 0.181 | 0.186 | 0.177 | 0.97 | 1.05 |
| interp | 0.505 | 0.514 | 0.503 | 0.98 | 1.02 |
| loop | 0.228 | 0.075 | 0.067 | 3.1 | 1.12 |
| methods | 0.241 | 0.007 | 0.006 | 33.8 | 1.10 |
| patterns | 0.216 | 0.212 | 0.213 | 1.02 | 0.99 |
| strings | 0.126 | 0.137 | 0.137 | 0.92 | 1.00 |
| tables | 0.100 | 0.092 | 0.078 | 1.09 | 1.18 |
| unicode | 0.039 | 0.008 | 0.008 | 4.7 | 1.00 |
| messages | 0.178 | 0.183 | 0.181 | 0.97 | 1.01 |

**Targets without a JIT (measurement 5).** Native code runs the benchmarks that spend their time in Lus code 3 to 34 times faster than the interpreter. It runs the benchmarks that spend their time in the library about as fast. Code compiled ahead of time is that native code, so a target that refuses executable memory gains the same factor. The work goes ahead.

**Startup and steady state (measurements 1 and 2).** Code compiled before its first call moved the benchmarks by between 20 percent slower and 18 percent faster than the default JIT, with most within 5 percent. The two that gained, `loop` and `tables`, run for less than 0.1 s, where the time before the optimizing tier compiles is a visible share of the run. `arrays` lost, because a function compiled on its first call has seen fewer samples than one compiled after 120 events. On a target with a JIT, code compiled ahead of time is therefore no reason to choose `--aot`, as `warmstart.md` found for baseline code. The training run compiles after the usual thresholds, so its code has the predictions of a warmed program and does not repeat the loss of `arrays`.

**Size (measurement 4).** In the static aarch64 Linux executable, a ReleaseSafe build with 5.66 MB of code, the parser takes 261 KB, the compiler 147 KB, the tools such as `lus test` and `lus debug` 309 KB, and the two JIT tiers 399 KB. An executable compiled ahead of time needs none of them by default, which leaves out 1.1 MB, about a fifth of the code. The sizes come from the symbol table of the executable, summed by the module that each function belongs to.

**Peak speed (measurement 3)** needs relocated code and is taken in step 3.

## Order of the work

1. The relocation interface in every assembler and the address sites in the code generators, with a test that compiles every conformance function for ahead of time and checks that each address it writes has a relocation.
2. `-Dcompiler=false` and its runtime, gated by the conformance suite with the tests that call `load` on source text skipped.
3. The training run, the code section, and the loader, gated by the conformance suite run from executables compiled ahead of time in every mode.
4. Library stripping.
5. Static linking for targets without executable memory, starting with iOS.

The equality saturation pass of the speed workstream plugs into step 3 as a pass that only the training run's compile enables.

## Decisions

- The executable records a seed per build, so every node prediction holds, at the cost described in "The training run".
- The runtime leaves out the JIT by default. `--aot-keep-jit` keeps it.
- Library stripping is the default whenever the proof succeeds.
