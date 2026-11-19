# Interpreter benchmarks

Each `.lus` file in this directory is a small program that stresses one part of the interpreter.

- `fib.lus`: recursive Lus calls and returns.
- `loop.lus`: a numeric `for` loop with integer arithmetic.
- `tables.lus`: table construction, constant-key fields, and array indexing.
- `methods.lus`: method calls through a metatable `__index` and table allocation.
- `strings.lus`: string interpolation, `table.concat`, and `string.gmatch`.
- `closures.lus`: closure creation with captured upvalues.

The runner times every benchmark under each runtime it finds and prints the best wall time of several runs. Build the runtime with ReleaseFast before measuring.

```sh
cd runtime
zig build -Doptimize=ReleaseFast
cd ..
tests/bench/run.sh        # three runs per benchmark
tests/bench/run.sh 5      # five runs per benchmark
```

The runtimes come from environment variables. `LUS` is the Lus 2.0 binary and defaults to `runtime/zig-out/bin/lus`. `LEGACY` is the 1.7 binary and defaults to `legacy/lus/build/lus`. `LUAJIT` is a LuaJIT binary and defaults to `luajit` on the path. LuaJIT runs with `-joff`, so the table compares interpreters only. A benchmark that uses Lus syntax has a plain Lua version in `lua/`, which LuaJIT runs instead. A runtime that is missing or fails shows a dash.

The last column is the Lus time divided by the legacy time. Numbers below one mean the new runtime is faster.
