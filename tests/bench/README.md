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

The runtimes come from environment variables. `LUS` is the Lus 2.0 binary and defaults to `runtime/zig-out/bin/lus`. `LEGACY` is the 1.7 binary and defaults to `legacy/lus/build/lus`. `LUAJIT` is a LuaJIT binary and defaults to `luajit` on the path. LuaJIT runs with `-joff`, so its column is its interpreter. Lus runs as it does by default, with its baseline JIT on. Set `LUS_JIT=off` in the environment to time the Lus interpreter alone. A benchmark that uses Lus syntax has a plain Lua version in `lua/`, which LuaJIT runs instead. A runtime that is missing or fails shows a dash.

The last column is the Lus time divided by the legacy time. Numbers below one mean the new runtime is faster.

## Warm starts

`warm/run.sh` measures warm starts (`spec/design/warmstart.md`). `warm/gen.lus` writes a program of many small functions that each turn hot after a few calls, and the script compiles it once cold and once with `lus compile --profile`. It prints the best wall time of each chunk, of the cold chunk under `LUS_JIT=off`, and of an empty script, and then one in-program timeline of each, which compares the first ten rounds with ten rounds at steady speed.

```sh
tests/bench/warm/run.sh            # 10 runs, 600 functions, 100 rounds
tests/bench/warm/run.sh 20 2000 30 # 20 runs, 2000 functions, 30 rounds
```
