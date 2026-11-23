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
- `http_serve.lus`: an HTTP server on `network.serve` that 64 client coroutines send 100,000 requests to over loopback, all in one process. It measures the scheduler, the sockets as suspension points, and the request parser together. LuaJIT has no counterpart, so its columns show dashes.
- `forfrom.lus`: iterates records with `for name, price, qty from` and with a generic for that reads the same fields by hand. Run directly, it prints the time and the allocated memory of each loop, which match because the `from` loop reads fields into locals and builds no table per step.
- `queries.lus`: queries over in-memory records: a join of two lists of 6,000 records on a key, a join of three lists with a range condition, an ordering with a small limit, a grouping into 100 groups, and a plain filter over 200,000 records. Run directly, it prints the best time of each case and a checksum that stays the same across builds. `lus tests/bench/queries.lus 25 group-100` runs one case 25 times (`spec/design/query-shortcuts.md`). LuaJIT has no counterpart, so its columns show dashes.
- `gcpause.lus`: builds and drops a 50 MB object graph four times. Besides its run time, it prints the longest gap between two loop iterations, which bounds the longest collector pause. Run it directly to see that number.
- `coio/`: the measurements of `spec/design/coroutine-io.md`, run by hand. `roundtrip.lus` times a resume and yield round trip against a plain call. `echo.lus PORT MODE` is a line echo server that reads and writes with the socket methods, with the ports `conn.input` and `conn.output`, or with plain coroutines around the methods, and `bun coio/load.mjs PORT 64 DEPTH 5` loads it with 64 connections that each keep `DEPTH` lines in flight.

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
| arrays | 0.033 | 0.151 | 0.205 | 0.246 | 0.038 |
| closures | 0.063 | 0.071 | 0.076 | 0.134 | 0.125 |
| data | 0.026 | 0.032 | 0.032 | 0.274 | 0.050 |
| fib | 0.008 | 0.028 | 0.034 | 0.036 | 0.010 |
| fullgc | 0.050 | 0.050 | 0.051 | 0.306 | 0.319 |
| gcpause | 0.412 | 0.424 | 0.382 | 0.474 | 0.460 |
| interp | 0.923 | 0.962 | 0.910 | 2.016 | 1.359 |
| loop | 0.066 | 0.146 | 0.215 | 0.268 | 0.091 |
| messages | 0.170 | 0.169 | 0.170 | - | - |
| methods | 0.006 | 0.164 | 0.207 | 0.245 | 0.006 |
| patterns | 0.206 | 0.207 | 0.208 | 0.265 | 0.257 |
| startup | 0.119 | 0.117 | 0.120 | - | - |
| strings | 0.145 | 0.144 | 0.139 | 0.248 | 0.206 |
| tables | 0.106 | 0.101 | 0.105 | 0.165 | 0.125 |
| unicode | 0.007 | 0.030 | 0.032 | 0.032 | 0.004 |

The baseline tier runs the hit paths of the interpreter's inline caches, array accesses for every element kind, and calls, returns, and tail calls between compiled functions without leaving native code. The optimizing tier adds typed values in machine registers, checks moved in front of loops, calls compiled inline, direct calls between optimized functions, and tables that are never allocated. `methods`, `arrays`, `loop`, and `unicode` are where it shows. `methods` builds a new object on every iteration through a method and a constructor, and its optimized loop adds two numbers. `unicode` takes the length of `string.sub` on a long non-ASCII string, which the optimizing tier computes from the positions. `fib` is all calls. The optimizing tier makes them as direct calls: an activation takes its argument in a machine register, calls itself with a native call, and gets a frame only when optimized code is left. That takes `fib` from 0.029 s to 0.008 s, level with LuaJIT. `data`, `gcpause`, `interp`, `patterns`, and `strings` measure the runtime underneath, so their three Lus columns agree. `tables` keeps three million tables alive, so its time goes to allocating and marking them. The collector reads each of them once, when it traces it, and waits for twice the usual growth while the heap only grows, which puts every Lus column ahead of LuaJIT with its JIT.

With the JIT off, the interpreter is ahead of the interpreter of LuaJIT on every benchmark that both run. `fib` and `unicode` are the close ones, and a single best of nine can show them level. Over 31 alternating runs, `fib` takes 0.0366 s against 0.0378 s at best and `unicode` 0.0328 s against 0.0342 s. `fib` shows the call and the return of the interpreter, which went from 0.062 s to 0.034 s. `unicode` went from 0.042 s to 0.033 s through `string.sub` finding its start from where the previous one started, opcodes that read their operands in place, and a string table hit that compares only the length and the bytes. LuaJIT slices bytes there, while Lus counts characters. `spec/design/interp.md` has the measurements behind both, and those of the designs that were tried and kept out.

Strings over 64 bytes travel between workers as shared blobs (`spec/design/workers.md`), and before blobs `messages` took 0.40 s. `fullgc` marks on several threads (`spec/design/gc.md`), and on one thread it takes 0.110 s.

The `lus off` column moves by a few percent between builds with the code layout of the interpreter loop. Compare the Lus columns of one build with each other, and read instruction counts for a change to the loop (`runtime/HACKING.md`).

## The HTTP server against Node

`http_serve.lus` also runs as a plain server when it receives a port, and `http_serve.js` is the same server on the `http` module of Node. Both answer every request with the same 14 bytes and a `Content-Type` header. An external load generator such as `oha` compares them.

```sh
runtime/zig-out/bin/lus tests/bench/http_serve.lus 8080 &
oha -z 10s -c 64 --no-tui http://127.0.0.1:8080/

node tests/bench/http_serve.js 8081 &
oha -z 10s -c 64 --no-tui http://127.0.0.1:8081/
```

`spec/design/coroutines.md` records the numbers this comparison gave.
