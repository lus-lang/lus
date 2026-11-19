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

Wall times in seconds, best of nine runs, ReleaseFast on an Apple silicon Mac, at the commit that made the collector mark objects as they pop from the gray stack and double its goal while the heap grows (`spec/design/gc.md`). The machine ran a few percent slower than for earlier tables, LuaJIT included, so compare the columns of this table with each other.

| benchmark | lus | lus baseline | lus off | luajit -joff | luajit |
|---|---:|---:|---:|---:|---:|
| arrays | 0.037 | 0.167 | 0.250 | 0.264 | 0.044 |
| closures | 0.076 | 0.082 | 0.101 | 0.149 | 0.139 |
| data | 0.031 | 0.037 | 0.037 | 0.296 | 0.057 |
| fib | 0.032 | 0.032 | 0.066 | 0.040 | 0.011 |
| gcpause | 0.457 | 0.452 | 0.422 | 0.474 | 0.436 |
| interp | 1.026 | 1.038 | 1.074 | 2.307 | 1.446 |
| loop | 0.061 | 0.150 | 0.227 | 0.259 | 0.094 |
| methods | 0.006 | 0.186 | 0.227 | 0.252 | 0.006 |
| patterns | 0.204 | 0.206 | 0.207 | 0.273 | 0.260 |
| strings | 0.161 | 0.180 | 0.178 | 0.272 | 0.221 |
| tables | 0.109 | 0.111 | 0.115 | 0.177 | 0.136 |
| unicode | 0.007 | 0.038 | 0.044 | 0.034 | 0.005 |

The baseline tier runs the hit paths of the interpreter's inline caches, array accesses for every element kind, and calls, returns, and tail calls between compiled functions without leaving native code. The optimizing tier adds typed values in machine registers, checks moved in front of loops, calls compiled inline, and tables that are never allocated. `methods`, `arrays`, `loop`, and `unicode` are where it shows. `methods` builds a new object on every iteration through a method and a constructor, and its optimized loop adds two numbers. `unicode` takes the length of `string.sub` on a long non-ASCII string, which the optimizing tier computes from the positions. `fib` is all calls, which both tiers make the same way. `data`, `gcpause`, `interp`, `patterns`, and `strings` measure the runtime underneath, so their three Lus columns agree. `tables` keeps three million tables alive, so its time goes to allocating and marking them. The collector reads each of them once, when it traces it, and waits for twice the usual growth while the heap only grows, which puts every Lus column ahead of LuaJIT with its JIT. `unicode` with the JIT off finds both ends of each substring from where the previous one ended.

The `lus off` column moves by a few percent between builds with the code layout of the interpreter loop. Compare the Lus columns of one build with each other.
