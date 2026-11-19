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
- `unicode.lus`: `string.sub` and `#` on a long string of mixed one to four byte characters. Lus counts characters, while legacy and LuaJIT count bytes, so this benchmark measures the cost of character indexing against plain byte slicing.
- `arrays.lus`: reading and writing arrays of integers and of floats from Lus code.
- `data.lus`: `table.sum`, `table.mean`, and `table.stdev` over large arrays of integers and floats. LuaJIT runs the same computation written as Lua loops in `lua/data.lua`.
- `gcpause.lus`: builds and drops a 50 MB object graph four times. Besides its run time, it prints the longest gap between two loop iterations, which bounds the longest collector pause. Run it directly to see that number.

The runner times every benchmark under each runtime it finds and prints the best wall time of several runs. Build the runtime with ReleaseFast before measuring.

```sh
cd runtime
zig build -Doptimize=ReleaseFast
cd ..
tests/bench/run.sh        # three runs per benchmark
tests/bench/run.sh 5      # five runs per benchmark
```

The runtimes come from environment variables. `LUS` is the Lus 2.0 binary and defaults to `runtime/zig-out/bin/lus`. `LEGACY` is the 1.7 binary and defaults to `legacy/lus/build/lus`. `LUAJIT` is a LuaJIT binary and defaults to `luajit` on the path. A benchmark that uses Lus syntax has a plain Lua version in `lua/`, which LuaJIT runs instead. A runtime that is missing or fails shows a dash.

The table has one column per configuration.

- `lus`: Lus 2.0 as it runs by default, with its baseline JIT on.
- `lus off`: Lus 2.0 with `LUS_JIT=off`, which is the interpreter alone.
- `legacy`: the 1.7 runtime.
- `luajit -joff`: the interpreter of LuaJIT.
- `luajit`: LuaJIT with its tracing JIT.
- `lus/legacy`: the `lus` time divided by the legacy time. Numbers below one mean the new runtime is faster.

## Results

Wall times in seconds, best of fifteen runs that alternate between the configurations, ReleaseFast on an Apple silicon Mac, at the commit that sized small hash parts exactly and gave natives frameless leaves (`spec/design/tables.md`, `spec/design/jit.md`). The legacy runtime was not built for this run.

| benchmark | lus | lus off | luajit -joff | luajit |
|---|---:|---:|---:|---:|
| arrays | 0.155 | 0.235 | 0.252 | 0.040 |
| closures | 0.079 | 0.095 | 0.147 | 0.136 |
| data | 0.036 | 0.041 | 0.303 | 0.058 |
| fib | 0.032 | 0.066 | 0.038 | 0.011 |
| gcpause | 0.410 | 0.421 | 0.497 | 0.432 |
| interp | 0.948 | 0.938 | 2.031 | 1.296 |
| loop | 0.149 | 0.225 | 0.253 | 0.093 |
| methods | 0.184 | 0.242 | 0.247 | 0.005 |
| patterns | 0.208 | 0.208 | 0.264 | 0.257 |
| strings | 0.163 | 0.159 | 0.311 | 0.246 |
| tables | 0.152 | 0.157 | 0.162 | 0.124 |
| unicode | 0.040 | 0.049 | 0.032 | 0.004 |

Native code runs the hit paths of the interpreter's inline caches, array accesses for every element kind, and calls, returns, and tail calls between compiled functions without leaving native code. Those are the instructions that `methods`, `arrays`, `tables`, and `fib` spend their time in. `data`, `gcpause`, `interp`, `patterns`, and `strings` measure the runtime underneath, so their two Lus columns agree. `unicode` measures `string.sub` on a long non-ASCII string, where Lus finds character positions and interns each result, and LuaJIT slices bytes. It is the one row where the interpreter alone stays behind LuaJIT's interpreter. `tables` keeps three million tables alive, so its time goes to allocating and marking them.

The `lus off` column moves by a few percent between builds with the code layout of the interpreter loop. Compare the two Lus columns of one build with each other.
