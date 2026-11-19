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
- `gcpause.lus`: builds and drops a 50 MB object graph four times. Besides its run time, it prints the longest gap between two loop iterations, which bounds the longest collector pause. Run it directly to see that number.

The runner times every benchmark under each runtime it finds and prints the best wall time of several runs. Build the runtime with ReleaseFast before measuring.

```sh
cd runtime
zig build -Doptimize=ReleaseFast
cd ..
tests/bench/run.sh        # three runs per benchmark
tests/bench/run.sh 5      # five runs per benchmark
```

The runtimes come from environment variables. `LUS` is the Lus 2.0 binary and defaults to `runtime/zig-out/bin/lus`. `LUAJIT` is a LuaJIT binary and defaults to `luajit` on the path. A benchmark that uses Lus syntax has a plain Lua version in `lua/`, which LuaJIT runs instead. A runtime that is missing or fails shows a dash.

The table has one column per configuration.

- `lus`: Lus 2.0 as it runs by default, with its baseline JIT and its optimizing tier.
- `lus baseline`: Lus 2.0 with `LUS_JIT=baseline`, which is the baseline JIT alone.
- `lus off`: Lus 2.0 with `LUS_JIT=off`, which is the interpreter alone.
- `luajit -joff`: the interpreter of LuaJIT.
- `luajit`: LuaJIT with its tracing JIT.
- `lus/luajit`: the `lus` time divided by the `luajit` time. Numbers below one mean Lus is faster.

## Results

Wall times in seconds, best of nine runs, ReleaseFast on an Apple silicon Mac, at the merge of direct calls between optimized functions (`spec/design/opt.md`) with the collector that marks objects as they pop from the gray stack (`spec/design/gc.md`).

| benchmark | lus | lus baseline | lus off | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.034 | 0.153 | 0.236 | 0.249 | 0.038 |
| closures | 0.064 | 0.073 | 0.081 | 0.132 | 0.126 |
| data | 0.026 | 0.032 | 0.033 | 0.276 | 0.050 |
| fib | 0.009 | 0.029 | 0.047 | 0.036 | 0.010 |
| gcpause | 0.385 | 0.396 | 0.401 | 0.436 | 0.419 |
| interp | 0.918 | 0.907 | 0.906 | 2.004 | 1.283 |
| loop | 0.057 | 0.145 | 0.222 | 0.269 | 0.091 |
| methods | 0.006 | 0.181 | 0.208 | 0.246 | 0.006 |
| patterns | 0.197 | 0.197 | 0.200 | 0.260 | 0.258 |
| strings | 0.145 | 0.141 | 0.141 | 0.250 | 0.206 |
| tables | 0.102 | 0.102 | 0.107 | 0.161 | 0.122 |
| unicode | 0.007 | 0.036 | 0.042 | 0.032 | 0.004 |

The baseline tier runs the hit paths of the interpreter's inline caches, array accesses for every element kind, and calls, returns, and tail calls between compiled functions without leaving native code. The optimizing tier adds typed values in machine registers, checks moved in front of loops, calls compiled inline, direct calls between optimized functions, and tables that are never allocated. `methods`, `arrays`, `loop`, and `unicode` are where it shows. `methods` builds a new object on every iteration through a method and a constructor, and its optimized loop adds two numbers. `unicode` takes the length of `string.sub` on a long non-ASCII string, which the optimizing tier computes from the positions. `fib` is all calls. The optimizing tier makes them as direct calls: an activation takes its argument in a machine register, calls itself with a native call, and gets a frame only when optimized code is left. That takes `fib` from 0.029 s to 0.009 s, level with LuaJIT. With the JIT off, `fib` shows the call and the return of the interpreter, which went from 0.062 s to 0.047 s and still trail the interpreter of LuaJIT. `data`, `gcpause`, `interp`, `patterns`, and `strings` measure the runtime underneath, so their three Lus columns agree. `tables` keeps three million tables alive, so its time goes to allocating and marking them. The collector reads each of them once, when it traces it, and waits for twice the usual growth while the heap only grows, which puts every Lus column ahead of LuaJIT with its JIT. `unicode` with the JIT off finds both ends of each substring from where the previous one ended.

The `lus off` column moves by a few percent between builds with the code layout of the interpreter loop. Compare the Lus columns of one build with each other.
