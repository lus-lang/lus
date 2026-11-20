# Cross-language benchmarks

This suite compares Lus with other dynamic language runtimes on small, realistic programs. Each directory holds one program written once per language, in the idiomatic style of that language and with its standard library first. Every program generates its input in process from the same Park-Miller generator, so all runtimes do the same work on the same data. The suite records wall time and peak memory for the compute programs, and throughput, latency, and memory for an HTTP server.

## Runtimes

The harness runs each program with the following commands.

| id | command |
| --- | --- |
| lus | `$LUS`, or `runtime/zig-out/bin/lus` built with `-Doptimize=ReleaseFast`, default JIT tiers |
| lua | `lua5.5` |
| luajit | `luajit` |
| luau | `luau -O2 --codegen` |
| python | `python3` |
| node | `node` |
| bun | `bun` |
| ruby | `ruby --yjit` |
| php | `php` with opcache and the tracing JIT enabled |

The Lua and LuaJIT versions share one `.lua` file. Node and Bun share one `.js` file.

## Running

Build Lus first, then run the harness from anywhere.

```sh
cd runtime && zig build -Doptimize=ReleaseFast && cd ..
node tests/bench/compare/run.mjs
```

The harness accepts these flags.

- `--only json,http` limits the run to some programs. The name `http` selects the server benchmark.
- `--runtimes lus,node` limits the run to some runtimes.
- `--runs N` sets the number of timed runs per cell, 5 by default.
- `--size small` times every program at its small size, which makes a quick check of the whole pipeline.
- `--http-duration 10s` and `--http-warmup 2s` set the load test lengths.
- `--merge` keeps earlier cells of `results.json` and replaces only the measured ones.

The harness prints a table and writes `results.json` with the device, the exact runtime versions, and every measurement. It needs `/usr/bin/time` and, for the HTTP benchmark, `oha`. Starting servers needs permission to listen on local ports.

## Measurements

The timed runs alternate between runtimes round-robin, so background noise spreads over all of them. Each cell keeps the best and the median wall time, and the peak resident memory of the best run as reported by `/usr/bin/time`.

The HTTP benchmark starts each server on a free port and waits until it answers. It then warms the server up and loads it with `oha -c 64` over keep-alive connections. It records successful requests per second, the median and 99th percentile latency, the error count, and the server memory at idle and at its peak during the load. Each server answers `GET /` with a JSON document built per request and every other path with 404. Node uses the `http` module, Bun uses `Bun.serve`, and Python uses `ThreadingHTTPServer`. Ruby, PHP, and Lus run small HTTP/1.1 servers on their standard socket libraries. The Lus server runs one coroutine per connection on a single interpreter. Lua 5.5, LuaJIT, and Luau have no sockets in their standard libraries, so they take part in the compute programs only.

## Correctness

Every program prints a single line with its name and an integer checksum. Before timing, the harness runs each program at its small size on every runtime and compares the lines. A runtime whose line differs from the majority is reported and left out of the timing for that program. The small size is one hundredth of the default size in the Python version. The HTTP benchmark checks the content type, the JSON body, the increasing counter, and the 404 answer before the load starts.
