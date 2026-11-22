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

Every site in `emit.zig` and `opt/codegen.zig` that writes an address passes its kind and its identity to the assembler, which records the relocation when it compiles for ahead of time and writes the address at once otherwise. The JIT path stays as it is. The code generators already funnel every address through `movImm` and `call`, with 61 sites that take `@intFromPtr` across the two files, so the change is a new argument at those sites and a relocation list in each assembler.

Speculation on an object that the runtime cannot rebuild by name, such as a table that the program built and a guard compares by identity, makes the builder drop that unit and keep the baseline code of its function.

## The executable

The executable is a prebuilt runtime, built with `-Dcompiler=false`, followed by the payload of `lus build` and a section of code objects with their relocations. The runtime without a compiler leaves out `src/syntax` and `src/compile` except the loader of binary chunks. `load` of source text raises "the compiler is not part of this executable". Prebuilt runtimes ship with each release for every target, as the release binaries do today.

At startup the runtime loads the chunks as `lus build` does, maps the code section, applies the relocations, makes the pages executable, and points each function at its code. On a target without executable memory, the code section lives in the executable image itself, linked at build time against the prebuilt runtime as a static library, which keeps the image signed as one piece. The relocations are then resolved by the system loader.

The runtime leaves out both JIT tiers by default, so code that the training run never reached runs in the interpreter. On a target that allows executable memory, `--aot-keep-jit` keeps them, so that code compiles at run time as it does under `lus build`.

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
