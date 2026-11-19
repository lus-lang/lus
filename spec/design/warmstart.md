# Warm starts

## Designs measured and kept out

### Feedback in binary chunks

A warm start lets a binary chunk carry the feedback of an earlier run, so that a second run starts with its hot functions already compiled. The version that was built and measured added an optional section after the chunk: one flag byte per function, set when the function had native code at the end of a profiling run, guarded by the runtime version, a hash of the chunk, and a checksum. `lus compile --profile` and `lus build --profile` ran the program once and wrote the section, and loading a chunk with a valid section compiled the flagged functions before the chunk returned from `load`.

The benchmark generated a program of many small functions, each with a twelve-iteration loop, and called every function once per round. Each program was compiled cold and with a profile. The table gives the best wall time of 20 runs of a ReleaseFast build on an Apple silicon Mac, and the time of the first ten rounds measured inside the program. "interpreter" is the cold chunk under `LUS_JIT=off`, and starting the executable with an empty script takes 2.5 ms.

| functions, rounds | interpreter | cold | warm | first 10 rounds cold | first 10 rounds warm |
| --- | ---: | ---: | ---: | ---: | ---: |
| 600, 100 | 10.2 ms | 14.0 ms | 13.2 ms | 0.79 ms | 0.94 ms |
| 100, 1000 | 15.4 ms | 16.0 ms | 16.0 ms | 0.14 ms | 0.15 ms |
| 2000, 30 | 11.1 ms | 12.9 ms | 13.7 ms | 3.63 ms | 2.70 ms |

Wall times moved by less than a millisecond either way, which is within the noise of these runs. The first rounds were faster only where many functions turn hot in a short run, and the warm chunk paid the same compile time at load instead. Loading the 2000 function chunk took 1.9 ms warm and 0.8 ms cold, for 95 functions compiled.

The cause is that a cold start has almost no warmup to save. A function compiles after 60 events (`jit.md`), so a hot function runs at most 60 interpreted calls or loop iterations, a few microseconds, before it has native code. A numeric loop of 16 or more iterations charges its whole count when it starts, so a function with a long loop compiles before the first iteration. Compiling costs the same whenever it happens, so moving it to the load gains nothing.

The other feedback a run gathers does not carry over to another process. The inline caches of table accesses hold hash node indices, and where a key lands depends on the hash seed of the state, which mixes in the address of the state and so differs from one process to the next. A cache also fills on the first execution of its instruction, so a persisted entry could save at most one lookup per instruction. The interpreter executes bytecode as the compiler wrote it, and the baseline JIT tests operand types on every execution, so there are no quickened opcodes to record.

Lus therefore keeps binary chunks free of feedback, and `lus compile` writes the same chunk as `string.dump`. Warm starts become worth measuring again with an optimizing tier whose speculative type feedback takes long to collect, where a cold start would spend a long time in slower code before that tier has what it needs.
