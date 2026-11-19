# Warm starts

A binary chunk can carry the feedback of an earlier run of the same program. When such a chunk loads, the functions that were hot in that run compile to native code at once, so the program runs at the speed of native code from its first instruction. This note describes what the feedback holds, how it is written and checked, how it is used, and what it gains.

## What the feedback holds

The feedback is one flag byte per function of the chunk. Bit 0 says that the function had native code when the profiling run ended. The other bits are zero.

That flag is the one decision a run makes that stays valid in another process. The interpreter executes bytecode exactly as the compiler wrote it, and the baseline JIT (`jit.md`) specializes at run time: its inline fast paths test the types of their operands on every execution and fall back to the interpreter's own code for the opcode. The only thing a run learns that a later run can reuse is which functions are worth compiling, and the first run spends its warmup learning exactly that.

The inline caches of table accesses (`IcEntry` in `vm/object.zig`) are kept out of the feedback on purpose. A cache entry is the index of a hash node, and where a key lands in the hash part depends on the hash seed of the state. The seed mixes in the address of the state, so it changes from one process to the next, and an index from another process would predict the wrong node almost every time. A cache also fills on the first execution of its instruction, so a persisted entry could save at most one lookup per instruction.

Nothing in the feedback is a pointer, an address, a hash, or anything else that depends on the process that wrote it.

## Format

The feedback is a section that follows the chunk written by `compile/dump.zig`. `compile/feedback.zig` writes and reads it.

| Field | Encoding |
| --- | --- |
| magic | the 7 bytes `LUSFDBK` |
| format version | one byte, currently 1 |
| runtime version | a length (unsigned LEB128) and the bytes of the version string, such as `Lus 2.0.0-dev` |
| chunk hash | 64-bit Wyhash, seed 0, of every byte of the chunk before the section, little endian |
| flags | a count (unsigned LEB128) and one byte per function |
| checksum | 64-bit Wyhash, seed 0, of the section from the magic to the last flag, little endian |

Functions are counted in the order the chunk stores them: the main function, then each nested function followed by its own nested functions, depth first.

The chunk itself is unchanged. A chunk followed by its feedback starts with the bytes of the same chunk without feedback, and `string.dump` never writes a section.

## Checks

The loader first reads the chunk as it always does. Bytes after the chunk must begin with the magic, and any other trailing bytes make the chunk malformed, as they did before sections existed. A section is then used only when every one of these holds:

- it parses completely and ends exactly at the end of the input,
- its checksum matches,
- every flag uses only known bits,
- its format version and runtime version equal those of the running runtime,
- its chunk hash equals the hash of the chunk it follows,
- it holds exactly one flag per function of the chunk.

A section that fails a check is ignored, and the chunk loads cold. A failed check never fails the load, because the chunk on its own is complete and correct. The loader never allocates for a section, and every read is bounds checked. The fuzz target for the chunk loader (`src/fuzz.zig`) appends sections to chunks before it damages and truncates them, and it checks that a section reported valid always has one flag per function.

A flag only decides when a function compiles. Native code computes exactly what the interpreter computes, so even a section that passed every check by accident could cost compile time and nothing else.

## Producing feedback

`lus compile --profile SCRIPT -- ARGS` compiles the script, runs the chunk once with the arguments after `--`, and writes the chunk followed by its feedback when the run succeeds. `-P` grants permissions to the run, and `-F` defines compile-time flags for both the compilation and the run. `lus build --profile` does the same for a standalone executable: it runs the bundle once and gives every module the run loaded a section of its own.

The profiling run is an ordinary run of the bundle (`runBundleProfiled` in `main.zig`). It installs a `feedback.Profile` in the state, and `api.load` then records each chunk it loads in a registry table under its chunk name, which keeps the function alive until the run ends. When the entry chunk returns, the profile reads the JIT state of every function of every recorded chunk. The run always counts with the JIT in its default mode, whatever `LUS_JIT` says, because those counters are what it reads.

## Using feedback

`api.load` checks the section of every binary chunk. When the section is valid and the JIT of the state runs in its default mode, each function flagged hot moves to the counting state with nothing left to count, and the JIT compiles it right there, before the chunk returns from `load`. A function the JIT declines stays in the interpreter, as it would at run time. An interpreted state has nothing to compile, and an eager state compiles every function on its first call already, so both load the chunk as if it had no feedback.

Compiling at load moves the compile time of the hot functions from the first moments of the run to the load. The functions do not wait for the sampler to notice them, and they run natively from their first call.

## Measurements

`tests/bench/warm/run.sh` generates a program of many small functions, each with a twelve-iteration loop that stays below the length at which the JIT charges a loop at once. The program calls every function once per round. It is compiled twice, cold and with `--profile`, and the script reports the best wall time of 20 runs of each, plus the time of the first ten rounds against ten rounds at the steady speed of the end of the run. Times are from a ReleaseFast build on an Apple silicon Mac. "interpreter" is the cold chunk under `LUS_JIT=off`, and starting the executable with an empty script takes 2.5 ms.

| functions, rounds | interpreter | cold | warm | first 10 rounds cold | first 10 rounds warm |
| --- | ---: | ---: | ---: | ---: | ---: |
| 600, 100 | 10.2 ms | 14.0 ms | 13.2 ms | 0.79 ms | 0.94 ms |
| 100, 1000 | 15.4 ms | 16.0 ms | 16.0 ms | 0.14 ms | 0.15 ms |
| 2000, 30 | 11.1 ms | 12.9 ms | 13.7 ms | 3.63 ms | 2.70 ms |

The gain is negligible. Wall times move by less than a millisecond either way, which is within the noise of these runs. The first rounds of the warm chunk are faster only where many functions turn hot while the run is short (the 2000 function case saves 0.9 ms there), and the warm chunk pays the same compile time at load instead: loading that chunk takes 1.9 ms against 0.8 ms cold, for 95 functions compiled.

The reason is the threshold. A function compiles after 60 events, so the warmup of a cold start is 60 interpreted calls or loop iterations per hot function, a few microseconds each. A warm start can save no more than that, and compiling costs the same whenever it happens. In these call-heavy programs the interpreter alone is fastest, because calls are where native code gains least today (`jit.md`). A loop of 16 or more iterations already compiles its function before its first iteration, so loop-heavy programs have almost no warmup to save.

Warm starts become worth more once compiling is expensive enough to need a higher threshold, or once the JIT keeps type feedback that takes many executions to gather. Both would reuse this section, with new flag bits or new fields behind a new format version.

## Open ends

- Functions compile at load even when the run never calls them. Compiling a flagged function on its first call would spread the cost and skip unused functions.
- `lus compile --profile` writes the feedback of the script itself, and modules that the script requires from source files start cold. `lus build --profile` covers every bundled module. Chunks that a program builds with `load`, and the chunks of workers, always start cold.
- A profiling run that ends with `os.exit` ends the process before the feedback is read, so nothing is written.
- Each profiling run replaces the feedback. Merging the profiles of several runs would cover programs whose hot functions vary with their input.
