# Ahead-of-time compilation

`lus build --aot` writes an executable that holds the machine code of the program, compiled by the two JIT tiers during a training run, next to the binary chunks that `lus build` already bundles. The executable starts with its hot code in place. It also runs on systems that refuse executable memory to ordinary programs, such as iOS and the game consoles, where a JIT cannot run at all. Its runtime leaves out the parser and the compiler, so `load` with source text raises an error there. Lus bundles no Zig compiler for it. The backends of the JIT emit the code, which a prebuilt runtime maps at startup.

## What it is for

The executable serves three cases, in this order of weight.

1. **Targets without a JIT.** iOS, the consoles, and processes under a policy that forbids executable memory run the interpreter today. Code compiled ahead of time is the only way native code reaches them.
2. **Size.** A program that never compiles source at run time needs neither the parser nor the compiler. A program that never reaches a library needs neither that library.
3. **Costly optimizations.** A pass whose compile time a JIT cannot afford can run once at build time. Equality saturation for vectorization, which the speed workstream is building, is the first such pass. It runs only under `--aot`.

Startup and peak speed on systems that have a JIT are not among the reasons. `warmstart.md` measured that a cold start has almost no warmup to save: a function compiles after 60 events, a long loop compiles before its first iteration, and moving the compile to load time saved nothing measurable. Code compiled ahead of time is the code the JIT would compile, so its steady state is the same speed. The measurements below check both statements before the work starts.

## The training run

`lus build --aot` runs the program once, with the arguments that `--train` names. The training run compiles every function it reaches to baseline code on its first call, and sends functions to the optimizing tier after the usual thresholds, so its units carry the predictions of a warmed program. When the run ends, the state writes the code of every function of every bundled chunk.

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

`LUS_JIT_AOT=check:PATH` makes both tiers compile every function in that form, with the real addresses in the patchable words, and run it. Every address that the resolver cannot name appends a line to PATH. Under it the conformance suite, the tests of the language server, and the examples of the documentation pass with an empty log. So the patchable forms run, and every address has a relocation.

`LUS_JIT_AOT=reload:PATH` checks the loader on the same code. After each function compiles, every relocated word is overwritten and written again from the address that the loader of an executable finds for its relocation. The metadata of each optimized unit, which its exits read, goes through the writer and the reader of the code section. The code then runs from what the loader produced. A relocation that the loader cannot resolve appends a line to PATH. The conformance suite and the tests of the language server pass with an empty log under the default JIT, `LUS_JIT=eager`, and `LUS_JIT=opt-eager`. CI runs it on macOS under the default JIT and `opt-eager`.

Speculation on an object that the runtime cannot rebuild by name, such as a table that the program built and a guard compares by identity, makes the builder drop that unit and keep the baseline code of its function.

## The executable

The executable is a prebuilt runtime, built with `-Dcompiler=false`, followed by the payload of `lus build` and a section of code objects with their relocations. The runtime without a compiler leaves out `src/syntax` and `src/compile` except the loader of binary chunks. `load` of source text raises "the compiler is not part of this executable". Prebuilt runtimes ship with each release for every target, as the release binaries do today.

The code section is a module of the bundle named `.aot`. It holds the hash seed of the training run, the strings that relocations name by their characters, a record of the baseline code of each function, and a record of each optimized unit. A unit record holds its code, the offsets of its entries, the metadata of its exits, and its relocations. A word of the metadata that holds an object, such as the key of a table that an exit allocates, is a relocation as well. The training run leaves out a unit whose code or metadata names an object without a name, and its function keeps its baseline code.

The runtime creates its state with the recorded seed and loads the chunks as `lus build` does. When a bundled module loads, the runtime numbers its functions, installs their baseline code, and reserves each of their units: a record and a block of executable memory. Units that call each other directly then find each other's addresses. A reserved unit is installed when every object that its relocations and its metadata name is here. It takes no direct calls before that, since a caller tests the cell of the unit before each call. A unit that names a function of a module that has not loaded yet waits for that module. On a target without executable memory, the code section lives in the executable image itself, linked at build time against the prebuilt runtime as a static library, which keeps the image signed as one piece. The relocations are then resolved by the system loader.

The runtime leaves out both JIT tiers by default, so code that the training run never reached runs in the interpreter. On a target that allows executable memory, `--aot-keep-jit` keeps them, so that code compiles at run time as it does under `lus build`.

### The runtime without a compiler

`zig build runtime` builds `lus-runtime` with `-Dcompiler=false` and `-Djit=false`, and `lus build --runtime lus-runtime` appends a bundle to it in place of the running `lus`. A reference to the compiler sits behind a check of the build option at compile time, so the compiler, the parser, the formatter, the linter, the tools, and the JIT are never compiled into it. What remains of `src/syntax` and `src/compile` is the reader and the writer of binary chunks and the parser of numbers that `tonumber` uses. Without a bundle the runtime prints that it runs only the bundle appended to it. `load` of source text returns nil and "the compiler is not part of this executable", and `debug.parse`, `debug.format`, and `debug.check` raise that error. Observed variables run an update function written in Lus, which `lus` compiles when a program first reaches them. `lus build --runtime` and `lus build --aot` bundle that function as a binary chunk in the module `.observe`, which the runtime loads in its place.

On an Apple silicon Mac in ReleaseFast, `lus-runtime` takes 6.37 MB against 8.70 MB for `lus`. A bundle of a benchmark from `tests/bench` takes 6.38 MB against 8.94 MB, and gives the same output. An empty bundle starts in 2.74 ms against 2.75 ms, the best of 150 alternating runs. Until code compiled ahead of time is appended, the runtime interprets, so the benchmarks that native code speeds up run as fast as under `LUS_JIT=off`. `zig build test-runtime` bundles `tests/build/app.lus` on the runtime and checks its output, and checks the message of `load`.

## Leaving out code

An executable compiled ahead of time holds only the code that its program can reach, as a Go or Rust executable does. `lus` links the executable itself, so `lus build --aot` needs no toolchain on the machine that runs it. The input is always the runtime of the same release, which keeps the linker small: one object of known origin, a closed set of relocation kinds per architecture, and no shared libraries apart from the system interface of each platform.

### What the program reaches

The builder proves from the bytecode which builtins the program can reach, conservatively. A program qualifies when every global access names a constant, `_ENV` is never read as a value, the debug library is not reached, and every `require` names a constant module. A global read by a constant name reaches that builtin, such as `print`. A library read by a constant name and then indexed by a constant field reaches that one builtin, such as `string.upper`. A library used as a value in any other way reaches all of it. Methods follow the names the program uses: an entry of a method table, such as `upper` in the string methods or `close` in the methods of files, is reached when the program reads a field of that name anywhere and the library that creates the values is reached. A field read with a key that is not a constant reaches every method of the reached libraries. Builtins that the code compiled ahead of time names by path are reached too, since native code calls them directly.

When the proof fails, the builder keeps every builtin and prints the first access that the proof could not name, so the result never depends on a guess. The runtime has a second kind of guarded code, features that a builtin enables, such as remote modules behind `require`. A `require` of a constant name that the bundle holds reaches only the bundled module, which leaves out the client of remote modules with its TLS, certificate, and decompression code.

### The link object

Each release ships, for each target, the runtime as a link object next to the prebuilt runtime. The release build compiles the runtime with `-Dcompiler=false`, one section for each function and each datum, together with libc where the target links it statically, `compiler_rt`, SQLite, and the compression codecs. A converter in `tools`, run only by the release build, reads those relocatable objects (ELF, Mach-O, or COFF) and writes the link object:

- The atoms: each function or datum with its kind (code, constant data, data, zeroed data, thread data, zeroed thread data), its alignment, and its bytes.
- The relocations of each atom: an offset, a kind from the closed set of the architecture, a target atom or import, and an addend.
- The imports, each with the system library that provides it.
- The roots: the entry point, initializers, the routines of `aot.routines`, and the natives by path.
- The guarded edges: for each registration of a builtin, its path and the relocations of its function and its fast path, and for each guarded feature, its name and its relocations.

The converter rejects any relocation outside the known set, so a construct the linker does not handle fails the release build, never a user's build. The registration of a builtin whose edges the linker drops holds a null function. The library skips such a registration when it builds its table.

### The linker

The linker marks every atom reachable from the roots, following the relocations of each marked atom and following a guarded edge only when the proof reached its path. It lays out the marked atoms by kind, applies the relocations, appends the payload and the code section, and writes the executable for the target:

- **Linux** gets a static ELF executable on musl: program headers, a TLS segment, and no dynamic section.
- **macOS and iOS** get a Mach-O executable that loads `libSystem` (and on iOS the frameworks the runtime calls), binds its imports with chained fixups, starts at `main` through `LC_MAIN`, and keeps thread data in `__thread_vars` for `dyld`. The linker signs the result ad hoc: a code directory of SHA-256 hashes of every page, as the system linker writes for an unsigned build. A developer signs it again for distribution with `codesign`.
- **Windows** gets a PE executable with an import directory for each DLL (`kernel32`, `ntdll`, `ws2_32`, `crypt32`, and the rest), base relocations, the TLS directory, and the unwind tables of the kept functions.

On a target that allows executable memory, the code compiled ahead of time stays the `.aot` module that the runtime relocates at load. On iOS it becomes atoms of the image, with relocations that name the runtime's atoms, so the system loader resolves them and the image is signed as one piece. A target that the linker does not support yet bundles on the prebuilt runtime as before.

### Testing

`lus build --aot --link-all` follows every guarded edge, which links the whole runtime from the link object. CI runs the conformance suite on that executable for each format, so the linked runtime behaves as the prebuilt one does. The test runtime links `tests/build/aot.lus` minimally and checks its output. A further test links, for each builtin path, a program that reaches only that builtin and calls it. Linux runs these in the virtual machine gate, macOS on the macOS runner, Windows on the Windows runner.

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

**What linking can leave out.** A `lus-runtime` in ReleaseFast on an Apple silicon Mac takes 6.59 MB. Without the four optional libraries it takes 3.73 MB, which is what leaving out whole libraries could reach. A build whose library tables hold only `print`, which Zig reduces to the code that `print` and the runtime reach, takes 2.76 MB, the size that the linker gives a hello world. That build still holds pieces that the guarded edges and small changes remove: an initialized table of 512 KB in the data of the shape registry, the client of remote modules at about 450 KB, the text of `lus agents` at 128 KB, the printer of stack traces at about 80 KB, and the writer of the code section, which only the training run uses.

**Peak speed (measurement 3).** The table gives the best wall time of five runs, in seconds, from a ReleaseFast build on an Apple silicon Mac. "build" is the executable of `lus build` on `lus`, with both JIT tiers. "runtime" is the same bundle on `lus-runtime`, which interprets. "aot" is the executable of `lus build --aot`, on `lus-runtime` with the code of the training run. Every executable prints the same output.

| benchmark | build | runtime | aot | aot size |
|---|---:|---:|---:|---:|
| arrays | 0.038 | 0.236 | 0.038 | 6.60 MB |
| closures | 0.081 | 0.102 | 0.080 | 6.59 MB |
| data | 0.030 | 0.039 | 0.029 | 6.60 MB |
| fib | 0.011 | 0.050 | 0.012 | 6.59 MB |
| loop | 0.075 | 0.249 | 0.081 | 6.58 MB |
| methods | 0.007 | 0.272 | 0.007 | 6.61 MB |
| patterns | 0.224 | 0.228 | 0.220 | 6.63 MB |
| strings | 0.157 | 0.145 | 0.153 | 6.60 MB |
| tables | 0.101 | 0.108 | 0.102 | 6.60 MB |
| unicode | 0.009 | 0.042 | 0.009 | 6.59 MB |

Code compiled ahead of time runs as fast as the JIT, as expected. The executable of `lus build` takes 8.98 MB. Without the recorded seed, `methods` and `unicode` ran at 0.202 s and 0.037 s, because the node predictions of their units failed and the units were given up.

## Order of the work

1. The relocation interface in every assembler and the address sites in the code generators, with a test that compiles every conformance function for ahead of time and checks that each address it writes has a relocation.
2. `-Dcompiler=false` and its runtime, gated by the conformance suite with the tests that call `load` on source text skipped.
3. The training run, the code section, and the loader, gated by the conformance suite under `LUS_JIT_AOT=reload` in every mode that compiles, and by an executable compiled ahead of time in `zig build test-runtime`.
4. Leaving out code, in this order: the reference graph, with registrations that skip a null function and the proof at the level of builtins. Then the converter, the link object, and the ELF linker for x86-64 and aarch64 Linux. Then Mach-O with signing, then PE. The other architectures follow with their relocation kinds.
5. Static linking for targets without executable memory, starting with iOS, on the Mach-O linker of step 4.

The equality saturation pass of the speed workstream plugs into step 3 as a pass that only the training run's compile enables.

## Decisions

- The executable records a seed per build, so every node prediction holds, at the cost described in "The training run".
- The runtime leaves out the JIT by default. `--aot-keep-jit` keeps it.
- Leaving out code is the default whenever the proof succeeds. `lus` links the executable itself, with no toolchain on the machine that builds it.
