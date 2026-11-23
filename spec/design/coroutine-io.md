# Coroutine I/O

This note measures what it costs to run data calls through coroutines: a connection reads from a source coroutine and writes to a sink coroutine, and a loop over input becomes a loop over a coroutine. The question is whether that form can be as cheap as the socket methods it would sit beside. If it cannot, Lus keeps one waiting form for every data call and builds it uniformly. The prototype lives on the branch `claude/coroutine-io`.

## The form under test

A connection has two coroutines.

- `conn.input` is a source. `coroutine.resume(conn.input, "*l", 1024)` returns `true` and the next line, and the arguments of the resume are the read request, with the patterns that `receive` takes. When the connection ends, the source returns nothing and is dead from then on, so the end of the input reads as the end of a coroutine.
- `conn.output` is a sink. `coroutine.resume(conn.output, data)` sends `data`. `coroutine.close(conn.output)` ends the sending side of the connection, and the peer reads the end of its input.

Errors come back the way they come back from any coroutine: `resume` returns `false` and the message. A source or a sink stays usable after an error, so a server that fails to write one response can still write the 500 that replaces it.

## Two ways to build it

**Plain coroutines.** Each direction is an ordinary coroutine whose body loops over the socket method and yields what it returns. Every read then costs a full switch: `resume` enters the interpreter on the stack of the coroutine, and the `yield` unwinds back out of it. Each coroutine also carries its own stack.

**Ports.** A port is a coroutine with no stack of its own. Its thread object points at a step, and `resume` on a port calls that step on the resuming thread with the port and the values of the resume (`runtime/src/lib/coroutine.zig`, `resumePort`). The step runs the same code as the socket method. When data is already buffered, it returns at once, so a resume is a native call and nothing switches. When it must wait, it suspends the resuming thread exactly as the method would (`spec/design/coroutines.md`, "Natives that run again"), and the scheduler calls `resume` again, which calls the native again. A port allocates nothing per resume. A socket creates its two ports on first use and keeps them in the user values of its userdata. Every candidate the plan listed is therefore covered by the design itself: the generic resume bookkeeping is skipped, nothing allocates per call, no frame exists to save or reuse, and buffered data returns straight from the buffer.

Both JIT tiers reach `resume` as an ordinary native call, which already costs less than a method call, so no tier needed new code.

`conn.input` and `conn.output` are fields of a userdata. The socket metatable keeps its methods table as `__index`, and a field getter registered for that metatable returns the two ports (`state.Global.fields`). `ops.index` consults the getter only after the methods table misses, so method lookups take the path they always took. A function `__index` would cost every method call on a socket 21 ns.

## Measurements

The machine is a Mac with 14 cores. Every run used ReleaseFast builds and started only while the one-minute load average was under 6. Runs interleave the variants round by round, and the order rotates each round. "Baseline" is local rewrite at 420884b4. "Off" is the prototype binary running the shipped connection code, which isolates the cost of the other changes. The programs are in `tests/bench/coio/`.

### Resume and yield

A round trip through a plain coroutine costs the same in every tier, and the prototype leaves it unchanged. A port resume costs less than a method call on the same socket, because it skips the method lookup.

| ns per call | interpreter | baseline JIT | optimizing tier |
| --- | ---: | ---: | ---: |
| plain coroutine, `resume` and `yield` | 29.3 | 28.7 | 30.7 |
| `coroutine.wrap` call and `yield` | 27.7 | 28.3 | 29.8 |
| port `resume(conn.output, "")` | 17.3 | 16.2 | 16.8 |

The method call `conn:send("")` on the same socket costs 25.6 ns with the default tiers, on the baseline and on the prototype alike.

A buffered line read costs 650 to 720 ns through the port and 640 to 760 ns through `conn:receive`. Most of that time is the copy that moves the rest of the socket buffer down after every line, which both forms share.

### HTTP server

The benchmark is `tests/bench/compare/http/server.lus` under `oha -c 64` for 10 seconds after a 2 second warmup, as the compare harness runs it. The first table gives the medians of 7 rounds with the order rotating, and the range of each variant in brackets.

| variant | req/s | range | p50 ms | p99 ms | peak MB |
| --- | ---: | --- | ---: | ---: | ---: |
| baseline | 136,686 | 102k to 145k | 0.471 | 0.603 | 10.5 to 11.1 |
| off | 136,298 | 135k to 140k | 0.475 | 0.561 | 10.6 to 10.8 |
| ports | 134,094 | 67k to 137k | 0.476 | 0.568 | 10.5 to 11.0 |
| plain coroutines | 130,313 | 127k to 139k | 0.488 | 0.585 | 9.1 to 9.3 |

Short bursts of load from other work on the machine hit single runs, which the minimum and the maximum show, so the medians carry the comparison. Ports sit 1.9% under the baseline and 1.6% under `off`, inside the spread of the baseline itself. Plain coroutines cost 4.7%, and they trail the baseline in every round that no burst hit.

Two more measurements resolve the gap between ports and the baseline. At a fixed load of 40,000 requests per second, the server spends a median of 9.0 µs of CPU time per request with ports and 9.1 µs on the baseline, over 5 rounds. The compare harness itself, run as `node tests/bench/compare/run.mjs --only http --runtimes lus,php,bun` in alternating pairs, measured these numbers.

| pair | Lus baseline | Lus ports | Bun | PHP |
| --- | ---: | ---: | ---: | ---: |
| 1 | 133,848 (p99 0.644) | 140,165 (p99 0.609) | 117,598 to 121,794 | 154,111 to 155,653 |
| 2 | 129,860 (p99 0.693) | 131,353 (p99 0.644) | 117,390 to 118,585 | 156,778 to 157,861 |

Ports matched or beat the baseline in both pairs, with a lower p99 each time.

### TCP line echo

A line echo server answers 64 connections from a Bun client. With depth 1, each connection waits for the echo before it sends the next line. With depth 32, each connection keeps 32 lines in flight, so most reads find their line already buffered.

| variant | depth 1 lines/s | depth 1 p99 ms | depth 32 lines/s | depth 32 p99 ms | peak MB |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline, `conn:receive` | 187,600 | 0.701 | 903,419 | 2.554 | 9 to 13 |
| prototype, `conn:receive` | 191,300 | 0.697 | 913,193 | 2.537 | 8 to 13 |
| ports | 190,000 | 0.677 | 936,062 | 2.433 | 8 to 13 |
| plain coroutines | 189,400 | 0.692 | 820,712 | 2.769 | 7 |

Depth 1 gives the medians of 8 rounds and depth 32 the medians of 4. With depth 1 every read waits for the network, and all four forms land inside the noise of the loopback round trip. With depth 32 the server does the work, and the order holds in every round: ports run 3.6% faster than the baseline because a resume skips the method lookup, and plain coroutines run 9% slower because every line costs a switch into the coroutine and back.

### Memory

A port takes 234 bytes, and a plain coroutine takes 1,301 bytes with its 64-slot stack. Peak server memory under the HTTP load stays within the spread of the baseline for ports.

## Verdict

Ports pass. HTTP throughput, p99 latency, and peak memory stay within the run-to-run spread of the baseline, the CPU time per request is the same, and the line echo is as fast with one line in flight and faster with many. No step of the candidate list was left to make cheaper, because a port has no switch, no frame, and no allocation per call to remove. The coroutine form can therefore be the data API of Lus without a cost.

Plain coroutines do not pass. They cost 4.7% on HTTP and 9% on buffered reads, and their semantics are wrong for a sink, as the next section shows. The coroutine form must be built on ports.

Lus stays ahead of Bun on HTTP with ports, by 11% to 15% in the harness runs, and Node, Python, and Ruby trail by more than a quarter in the recorded results. PHP was ahead of Lus on HTTP throughput in all four harness runs, with ports and with the baseline alike, at 154k to 158k requests per second against 130k to 140k. Lus kept the better p99 in every run. The recorded `results.json` shows Lus 0.4% ahead of PHP, so that lead was already within the noise before this experiment, and it needs its own work.

## What the coroutine form fixes

The source form also settles a case the method form gets wrong. At the end of a connection, `conn:receive("*l")` returns an empty vector, which is also what an empty line returns, so a program cannot tell a blank line from the end of the stream. The source returns the empty line as a line and ends at the end of the stream.

Plain coroutines make a poor substitute for ports beyond their cost. A plain coroutine dies with its first error, so the response sink of `network.serve` built that way cannot write the 500 that replaces a failed response, and 13 tests of `serve_test.lus` fail on it.

## The shipping form

**Loops.** A generic `for` whose iterator is a coroutine resumes it with no values before each pass and binds the values of its `yield` to the loop variables in order. The loop ends when the coroutine returns, and the values it returns are dropped. It also ends at a `yield` whose first value is `nil`, the rule of every generic `for`, which costs nothing because the loop instructions stay as they are. `tforprep` sees the coroutine once, puts the native `coroutine.iterate` in the iterator slot and the coroutine in the state and closing slots, and the loop then runs as a loop over a native iterator in every tier. The coroutine is the closing value, so a `break`, a `return`, or an error in the body closes it. An error in the coroutine closes it and leaves the loop with that error. For the closing value to work, a coroutine is a valid value of a `<close>` variable, and it closes as `coroutine.close` closes it.

**The step of a port.** A port step receives the port and the values of the resume, and it reads no frame. `network.lines`, the request bodies of `network.fetch`, and the bodies that a handler of `network.serve` returns all resume streams from inside their own natives, and they drive ports the same way they drive coroutines. The step pushes its results, and `resumePort` moves them over the values of the resume, so a port consumes its arguments as any coroutine does. A step that waits runs again from its start when the native that resumed the port runs again.

**One resumer at a time.** A port records the thread that resumes it while its step runs. A second thread that resumes the port while the first one waits inside it receives `false` and `"cannot resume non-suspended coroutine"`, as it would from a coroutine that runs. The port counts as busy only while that thread still waits inside it, so a thread that was cancelled or closed during its wait leaves the port free.

**Ports in the library.** `conn.input`, `conn.output`, and `server.accepted` are ports, created on first use and kept in the user values of their userdata. The body streams of `network.fetch` and `req.reader`, and `sock:reader`, are ports too, with the state of the stream as their context. They replace generator natives, which ran each part through a full coroutine switch on a thread with its own stack, and the runtime has one mechanism for coroutines that it owns. `receive`, `send`, and `accept` stay. They return `nil` and an error object where the ports raise, and code that reads one message does not need a coroutine for it.

**`network.serve`.** The connection code of `serve` keeps calling its natives directly. A request port and a response port measured within noise of the natives in the experiment, and they would change nothing a handler sees. The streams a handler sees, `req.reader` and the bodies it returns, are ports.

## Where the code is

- `state.Port`, the `port` and `port_ctx` fields of `Thread`, and `state.newPortThread`.
- `coroutine.newPort`, `resumePort`, `closeCo`, `forPrep`, and `iterate`, and the `tforprep` and to-be-closed paths of `vm/interp.zig`.
- The ports of sockets and servers, and the field getter in `ops.index` (`state.Global.fields`).
- The stream ports of `lib/http.zig`.
- `tests/conformance/forco_test.lus` and `tests/conformance/port_test.lus`, and the programs of `tests/bench/coio/`.
