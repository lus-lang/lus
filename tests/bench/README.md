# Interpreter benchmarks

Each `.lus` file in this directory is a small program that stresses one part of the interpreter.

- `fib.lus`: recursive Lus calls and returns.
- `loop.lus`: a numeric `for` loop with integer arithmetic.
- `tables.lus`: table construction, constant-key fields, and array indexing.
- `methods.lus`: method calls through a metatable `__index` and table allocation.
- `strings.lus`: string interpolation, `table.concat`, and `string.gmatch`.
- `closures.lus`: closure creation with captured upvalues.
- `patterns.lus`: `find`, `match`, `gmatch`, `gsub`, and `upper` over ASCII text, with plain searches, literal prefixes, captures, and classes.
- `interp.lus`: building many short strings with interpolation, `..`, `upper`, `string.format`, and `table.concat`.
- `unicode.lus`: `string.sub` and `#` on a long string of mixed one to four byte characters. Lus counts characters, while LuaJIT counts bytes, so this benchmark measures the cost of character indexing against plain byte slicing.
- `arrays.lus`: reading and writing arrays of integers and of floats from Lus code.
- `data.lus`: `table.sum`, `table.mean`, and `table.stdev` over large arrays of integers and floats. LuaJIT runs the same computation written as Lua loops in `lua/data.lua`.
- `messages.lus`: sends a 1 MB string 2,000 times and a table of 10,000 strings of 100 bytes 300 times to a worker, which replies with the length of each message. Strings over 64 bytes travel as shared blobs (`spec/design/workers.md`).
- `startup.lus`: creates 2,000 workers with an empty body one after the other. Each worker starts a state and opens the standard library, so this measures how fast a state starts (`spec/design/snapshot.md`).
- `fullgc.lus`: builds a graph of a million live tables and collects it in full ten times, which measures marking while the program waits. On native targets those collections mark on several threads (`spec/design/gc.md`).
- `gcpause.lus`: builds and drops a 50 MB object graph four times. Besides its run time, it prints the longest gap between two loop iterations, which bounds the longest collector pause. Run it directly to see that number.

The runner times every benchmark under each runtime it finds and prints the best wall time of several runs. Build the runtime with ReleaseFast before measuring.

```sh
cd runtime
zig build -Doptimize=ReleaseFast
cd ..
tests/bench/run.sh        # three runs per benchmark
tests/bench/run.sh 5      # five runs per benchmark
```

The runtimes come from environment variables. `LUS` is the Lus 2.0 binary and defaults to `runtime/zig-out/bin/lus`. `LUAJIT` is a LuaJIT binary and defaults to `luajit` on the path. A benchmark that uses Lus syntax has a plain Lua version in `lua/`, which LuaJIT runs instead. A runtime that is missing or fails shows a dash. `messages` and `startup` use workers, which LuaJIT does not have, so its columns show dashes for them.

The table has one column per configuration.

- `lus`: Lus 2.0 as it runs by default, with its baseline JIT and its optimizing tier.
- `lus baseline`: Lus 2.0 with `LUS_JIT=baseline`, which is the baseline JIT alone.
- `lus off`: Lus 2.0 with `LUS_JIT=off`, which is the interpreter alone.
- `luajit -joff`: the interpreter of LuaJIT.
- `luajit`: LuaJIT with its tracing JIT.
- `lus/luajit`: the `lus` time divided by the `luajit` time. Numbers below one mean Lus is faster.

## Results

Wall times in seconds, best of nine runs, ReleaseFast on an Apple silicon Mac, with parallel marking, shared worker strings, the shorter call, return, and table paths of the interpreter, the fused instructions, and the faster forward scans of `string.sub` all merged.

| benchmark | lus | lus baseline | lus off | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.034 | 0.150 | 0.201 | 0.243 | 0.038 |
| closures | 0.062 | 0.071 | 0.075 | 0.132 | 0.122 |
| data | 0.026 | 0.032 | 0.032 | 0.270 | 0.050 |
| fib | 0.008 | 0.028 | 0.034 | 0.035 | 0.010 |
| fullgc | 0.051 | 0.051 | 0.051 | 0.313 | 0.315 |
| gcpause | 0.391 | 0.389 | 0.390 | 0.439 | 0.404 |
| interp | 0.920 | 0.904 | 0.897 | 2.004 | 1.281 |
| loop | 0.057 | 0.142 | 0.211 | 0.264 | 0.091 |
| messages | 0.167 | 0.166 | 0.167 | - | - |
| methods | 0.006 | 0.160 | 0.201 | 0.246 | 0.006 |
| patterns | 0.198 | 0.196 | 0.196 | 0.261 | 0.256 |
| startup | 0.118 | 0.116 | 0.117 | - | - |
| strings | 0.144 | 0.140 | 0.139 | 0.250 | 0.208 |
| tables | 0.104 | 0.101 | 0.101 | 0.159 | 0.124 |
| unicode | 0.007 | 0.029 | 0.034 | 0.031 | 0.004 |

The baseline tier runs the hit paths of the interpreter's inline caches, array accesses for every element kind, and calls, returns, and tail calls between compiled functions without leaving native code. The optimizing tier adds typed values in machine registers, checks moved in front of loops, calls compiled inline, direct calls between optimized functions, and tables that are never allocated. `methods`, `arrays`, `loop`, and `unicode` are where it shows. `methods` builds a new object on every iteration through a method and a constructor, and its optimized loop adds two numbers. `unicode` takes the length of `string.sub` on a long non-ASCII string, which the optimizing tier computes from the positions. `fib` is all calls. The optimizing tier makes them as direct calls: an activation takes its argument in a machine register, calls itself with a native call, and gets a frame only when optimized code is left. That takes `fib` from 0.029 s to 0.008 s, level with LuaJIT. `data`, `gcpause`, `interp`, `patterns`, and `strings` measure the runtime underneath, so their three Lus columns agree. `tables` keeps three million tables alive, so its time goes to allocating and marking them. The collector reads each of them once, when it traces it, and waits for twice the usual growth while the heap only grows, which puts every Lus column ahead of LuaJIT with its JIT.

With the JIT off, the interpreter is ahead of the interpreter of LuaJIT on eleven of the thirteen benchmarks that both run. `fib` shows the call and the return of the interpreter, which went from 0.062 s to 0.047 s and then to 0.034 s. It runs about 1130 million machine instructions against 880 million for LuaJIT, at more of them per cycle, and the two are level within the noise of repeated runs. `unicode` went from 0.042 s to 0.034 s, mostly because each `string.sub` now finds its start from where the previous one started. It still trails LuaJIT, which slices bytes where Lus counts characters, by 4 to 10 percent across sets of alternating runs. `spec/design/interp.md` has the instruction and cycle counts behind both, and the measurements of the designs that were tried and kept out.

Strings over 64 bytes travel between workers as shared blobs (`spec/design/workers.md`), and before blobs `messages` took 0.40 s. `fullgc` marks on several threads (`spec/design/gc.md`), and on one thread it takes 0.110 s.

The `lus off` column moves by a few percent between builds with the code layout of the interpreter loop. Compare the Lus columns of one build with each other, and read instruction counts for a change to the loop (`runtime/HACKING.md`).
