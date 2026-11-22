# Coroutines and I/O

Concurrency in Lus is coroutines. A program hands a coroutine to the runtime with `coroutine.detach`, and the runtime resumes it whenever what it waits for is ready. Blocking operations are the suspension points, and the language has no syntax for them: a function that reads a socket is the same function in the main chunk, in a plain coroutine, and in a detached one. This note records how the runtime does that (`runtime/src/vm/sched.zig`, `runtime/src/lib/coroutine.zig`, `runtime/src/lib/network.zig`, `runtime/src/lib/serve.zig`) and what it costs.

## The surface

- `coroutine.detach(co, ...)` hands the suspended coroutine `co` to the scheduler and returns it. The scheduler resumes it the first time with the extra arguments, as the arguments of its body or as the results of its pending yield, and afterwards whenever what it waits for is ready.
- `coroutine.yield(...)` inside a detached coroutine gives the next turn to the others. Its values are dropped and it returns nothing.
- `coroutine.resume(co, ...)` on a detached coroutine waits until `co` has ended and returns what `resume` returns for any coroutine that ends: `true` and the results, or `false` and the error. A coroutine that ended earlier keeps its results until the first resume collects them, every caller that already waited when it ended receives them as well, also when one of them closes the coroutine before the others ran, and a later resume returns `false, "cannot resume dead coroutine"`. Extra arguments are ignored.
- `coroutine.close(co)` cancels a detached coroutine and closes its pending to-be-closed variables.
- `coroutine.status(co)` reports `"suspended"` for a detached coroutine that waits.
- A detached coroutine that fails with nothing left to collect its error stops the program with that error and its traceback.

The return values of `coroutine.resume` are the same for every coroutine. `tests/conformance/detach_test.lus` runs each body once as a plain coroutine and once detached and compares the two results value by value.

## Natives that run again

A coroutine yields by unwinding. `coroutine.yield` marks its thread as yielding and returns an error, the call machinery of the interpreter turns that error into `error.Yield`, and it travels up to `resume` while every frame stays on the stack of the coroutine, the frame of the native `yield` included. A later resume finishes that native frame with the resume arguments as its results and continues the interpreter.

A wait uses the same path. A native that would block describes what it waits for in the scheduler record of its thread (`sched.Task`) and returns the same error (`sched.suspendThread`). The difference shows when the coroutine continues: `interp.restartNative` calls the native of the top frame again, with the arguments that are still on the stack, and then finishes the frame with the results of that second call. An error of the second call looks for a handler in the Lus frames below, as an error of the first call would.

Every builtin therefore stays one Zig function with one calling convention, and the path of an ordinary call is the path it was: a native that never waits pays nothing, and `interp.callNative`, the frameless leaf calls, and the calls between Lus functions are untouched. A native that waits is written as a loop that tries its operation without waiting and asks the scheduler to wait when the operation would block. What it has done so far lives outside its locals: the bytes a socket has received are in the buffer of the socket, the count of bytes a send has written is in the scheduler record, and a connection attempt in progress is a small record that the scheduler releases if the coroutine is closed.

Both JIT tiers reach natives through `interp.callNative`, and a yield leaves compiled code through the status that a step returns (`spec/design/jit.md`, "Yields"). A wait is that same status, so compiled code needs no knowledge of it. The frame of a compiled function stays on the Lus stack with its saved pc, and after the native has run again the coroutine enters native code at that pc, in whichever tier the function has code for. A yield happens in a function that baseline code or the interpreter runs, above frames that an exit of optimized code built (`spec/design/opt.md`), and a wait happens in the same place. The WebAssembly build follows the same rule with its own status code.

## Waits through plain coroutines

A plain coroutine that waits inside a detached one must suspend the detached one too. `coroutine.resume` and the function that `coroutine.wrap` returns handle that. When the coroutine they resumed comes back with a wait, they record an inner wait that points at it and suspend their own thread the same way. The scheduler follows the inner waits from the detached coroutine down to the native that asked, and registers the detached coroutine for that event. When the event arrives, the detached coroutine runs its `resume` native again, which runs the inner coroutine again, down to the native that waited. A generator that reads a socket therefore works unchanged inside a detached coroutine, and it still yields its values to the code that resumed it.

A thread can suspend at a wait when no native call holds its stack and every thread between it and a detached coroutine was resumed by `resume` or by a wrapped function (`sched.canSuspend`). Any other thread keeps its native on the stack and runs the scheduler from inside it until its own event arrives (`sched.block`). That is the main chunk, a plain coroutine that no detached coroutine resumed, and code that a native calls back, such as the comparison function of `table.sort`. A detached coroutine that waits inside such a callback stays in the running state for that wait, and its later waits outside the callback suspend it again. Blocking operations keep their meaning everywhere, and the detached coroutines of the program make progress whenever anything waits.

## The scheduler

Each state has one scheduler.

- The run queue is a list of coroutines in the order in which they became ready. A pass runs the coroutines that were queued when it started, so a coroutine that yields in a loop takes one turn per pass.
- Deadlines live in a binary heap on the monotonic clock. Each waiter knows its index in the heap, so a wait that ends early removes its deadline at once. A socket timeout is such a deadline, and the native that runs again after it raises the error it always raised (`"receive timeout"`, `"send timeout"`, `"sendto timeout"`, `"accept timeout"`). The timeout runs from the first wait of an operation. The scheduler record of the thread holds the deadline of the pending operation, and the frame of the native carries a mark that ties the deadline to that call. A native that finds its operation still blocked after a wake, as an acceptor does when another acceptor took the connection, waits for the rest of the same timeout. Progress ends the deadline, so every read of a socket has the whole timeout, as it has in a program without coroutines.
- The poller reports sockets that became readable or writable. It is kqueue on macOS and the BSDs, epoll on Linux, a poll request to the AFD driver on Windows, and `poll` on other POSIX systems. The WebAssembly build has no sockets, and its poller sleeps until the next deadline with a clock subscription of `poll_oneoff`. A kqueue or an epoll instance needs a file descriptor. When the process has none left, or when the poller takes no registration for a handle, the scheduler asks `poll` about the handles concerned together with the descriptor of the poller, so waits keep their deadlines and the other coroutines keep running.

After each pass the scheduler asks the poller once. It waits there without a limit when nothing is ready, until the next deadline when one exists, and not at all when coroutines are queued. Coroutines that only wait for each other can never continue, and the thread that would wait for them receives a deadlock error.

On kqueue and epoll a socket is registered once, edge triggered, and stays registered until it closes. That is sound because a native waits only after its operation reported that it would block, so the next edge always follows the wait. Registrations on kqueue collect in a change list that the next `kevent` call submits together with its wait, so a request that waits once costs one system call for the wait. Several coroutines may wait for one socket, such as several acceptors on one server. An event wakes all of them, and those that find nothing wait again. Closing a socket wakes its waiters, which then find the socket closed.

A TCP socket switches to non-blocking mode the first time an operation on it must not block. A send with `MSG_DONTWAIT` alone still blocks on macOS once it has written a part of its data, and a single mode for both directions keeps the paths the same on every system. While no detached coroutine exists and no timeout is set, an operation blocks in its system call exactly as before, so programs that use no coroutines make the same system calls they always made.

`sched.enableNotify` gives other threads a way to wake a scheduler that waits in its poller: a user event of kqueue, an eventfd of epoll, a pipe, or an event object on Windows. `sched.notify` sets a flag and triggers that source from any thread, and calls that arrive before the scheduler looks count as one. A native that waits for another thread calls `sched.waitNotify`. Every such waiter runs again after a `notify`, looks at what it waits for, and waits again when that is not there yet. A native reads its condition in the thread of the state before it waits, and the other thread changes the condition before it calls `notify`, so a change always ends the wait.

## Workers

`worker.receive` and `worker.peek` are suspension points (`runtime/src/lib/worker.zig`). In a state with detached coroutines they wait with `sched.waitNotify`. The domain of a creator and the inbox of a worker each remember the state whose scheduler they wake, from the first such wait on, and whoever changes a mailbox calls `sched.notify` for that state under the lock of the mailbox. In a state without detached coroutines both functions sleep on their condition variable, so a program that uses workers alone makes the system calls it always made. The same holds on a system that gives the scheduler no wake source.

A worker runs the coroutines that its body detached after the body has returned, as `lus` does after the main chunk, and it ends when the last of them has ended. The error of one that failed with nothing left to collect it becomes the error of the worker, which the next `worker.receive` of the creator raises. When the creator closes, it shuts its workers down and wakes their schedulers. A worker that still runs coroutines then stops waiting and closes them with its state.

## The collector

A detached coroutine is a root from `detach` until it ends, so a server whose only reference is its own socket wait stays alive. The scheduler keeps the unfinished coroutines in a list that the collector marks with its other roots, at the start of a cycle and again in the atomic phase, since a coroutine may be detached while a cycle runs. A finished coroutine is an ordinary object again. Its results stay on its own stack until a resume collects them, so they are traced like any stack.

A detached coroutine that failed registers with the collector the way an object with a `__gc` metamethod does. When it becomes unreachable with its error still uncollected, the collector keeps it for one more cycle, and the next safe point raises its error with its traceback as an error that no handler catches. `lus` reports the same error when it has run the remaining coroutines after the main chunk.

## `network.serve`

`serve` is a native that accepts connections in a loop and waits through the scheduler like any other native. It keeps the server, the handler, and whether it bound the server itself in its own argument slots, which survive its runs. Each connection gets a detached coroutine whose body is a 30 line Lus function, compiled the first time a state serves: read a request, call the handler under `catch`, write the response, and repeat while the connection stays open. Reading a request and writing a response are natives, and the state of an exchange lives in the socket: how far the search for the end of the headers got, the decoded part of a chunked body, and the unsent part of the response. The handler is called from Lus code, so it may wait itself.

The handler receives `{ method, path, query, headers, ip, port, body, reader }` and returns `status, body, headers`, in the order in which `network.fetch` returns them. The server calls it once the head of the request arrived. `body` reads the whole body on its first use, and `reader` is a coroutine that yields the body part by part, so the body stays in the socket until the handler asks for it. A body may also be a coroutine that yields the chunks of a streamed response. A handler error, or a result that makes no response, answers 500 and closes the connection. The error goes to the `on_error` function of the options, or to standard error in the form that `lus` gives the error that ends a program, so a program sees the errors of its handlers without any setup. The request line and headers are limited to 64 KiB and 128 lines, and `body` to 16 MiB. A head beyond a limit is answered with 431 before the handler runs, and a body that breaks its framing or its limit while the handler reads it is answered with 400, 413, or 431, and the connection closes. A body leaves the buffer of the socket as it is decoded, so the buffer holds what one read brought. The framing of a chunked body, which is its chunk lines with their extensions and its trailers, is limited to 64 KiB plus 8 bytes for every byte of the body, so the bytes a request sends stay within a fixed multiple of the body it delivers. `network.serve(server, handler)` takes a bound server, so a program can bind port 0 and learn the port before it serves.

A server protects itself from clients that hold connections. Every accepted socket carries the idle timeout of the options as its socket timeout, 60 seconds by default, so a read of a request or a write of a response that makes no progress for that long ends the connection. A connection that was idle between two requests closes quietly, and one that stopped inside a request is answered with 408. The server counts its open connections in the record of the listening socket, and every accepted socket points back at that record and leaves the count when it closes. At `max_connections`, which defaults to half of the descriptor limit of the process, `serve` stops accepting and waits with `sched.waitNotify`. A socket that closes calls `sched.signal`, which runs that wait again from the thread of the state. An accept that fails for lack of a descriptor or of memory waits the same way with a deadline of 100 ms and tries again, so the server outlives a shortage.

## Events as coroutines

A function that waits for something to happen returns a coroutine whose resume waits for the next occurrence: `p.exit` of `os.spawn` for the exit of a process, `os.signal` for a signal, `fs.watch` for a change to a file, and `coroutine.sleep` for the end of a time (`runtime/src/lib/events.zig`). Operations that transfer data, such as reading a pipe or a socket, keep waiting inline as suspension points. A coroutine that the runtime made this way carries a flag, and closing a coroutine that waits in a resume of one closes it too, so cancelling a task also ends its sleep or its watch. A sleep of `math.huge` waits with the `park` kind of the scheduler, which registers no timer and no handle, so only closing the sleep ends it. The scheduler counts parked detached coroutines apart, and `drain` returns once every detached coroutine left is parked, since nothing could wake them.

The coroutine is a plain one whose body calls a native that waits and yields its results, so the rule of [waits through plain coroutines](#waits-through-plain-coroutines) gives it the right behavior everywhere. Resumed from a detached coroutine, the wait suspends that coroutine. Resumed anywhere else, it blocks while the detached coroutines run. A coroutine that hands over a series of events holds its handle in a to-be-closed variable and stops at a first yield when it is created, so `coroutine.close` releases the handle even before the program resumed it. The two bodies are a dozen lines of Lus compiled once per state.

Signals and child exits reach the states through one watcher per process (`runtime/src/vm/sigwatch.zig`). On POSIX systems the signal handler counts the signal and writes its number to a pipe. A thread reads the pipe and calls `sched.notify` for every state that subscribed, which runs the natives that wait with `sched.waitNotify` again. Each native compares the counts with what it delivered, so no signal is lost between two resumes. The handler of SIGCHLD stays installed once a process was spawned. The watcher thread reaps the children whose process objects were collected while they ran. On Windows the console control handler and the wait callbacks of process handles already run on threads of their own and notify the states directly.

The pipes of `os.spawn` are in non-blocking mode on POSIX systems and wait in the poller like sockets. Windows anonymous pipes cannot join the poller, so a pipe that is empty or full lets the other coroutines run and looks again after 5 ms. inotify descriptors wait in the poller as well. FSEvents and `ReadDirectoryChangesW` deliver their events on threads of their own, which put them in a queue and notify the state.

## Measurements

The numbers come from ReleaseFast builds on an Apple silicon Mac (macOS, kqueue) and are the best of several runs.

### HTTP

`tests/bench/http_serve.lus` and `tests/bench/http_serve.js` answer every request with 14 bytes of text. `oha -z 10s -c 64 --no-tui` drives each over loopback with 64 keep-alive connections.

| Server | Requests per second | Average latency | 99th percentile |
| --- | ---: | ---: | ---: |
| Lus, `network.serve` | 144,700 | 0.44 ms | 0.52 ms |
| Node 22.23, `http` | 103,200 | 0.62 ms | 1.22 ms |

Both servers use one thread. A request on a connection that is already open costs four system calls in Lus: a receive that returns the request, a send for the response, a receive that reports that the socket is empty, and the `kevent` call that waits for the next request and returns many ready sockets at once under load.

### Coroutines

| Operation | Before | After |
| --- | ---: | ---: |
| Round trip through a wrapped plain coroutine | 26 ns | 26 ns |
| `resume(co, v)` and `yield` of a plain coroutine | 27.5 ns | 27.4 ns |
| Create and resume a plain coroutine | 105 ns | 105 ns |
| One turn of a detached coroutine that yields | | 17 ns |
| Create, detach, run, and collect a detached coroutine | | 140 ns |
| Echo of 4 bytes over loopback between two detached coroutines | | 11.6 µs of CPU |
| Memory of a suspended detached coroutine, with its stack of 64 values | | 1.6 KB |

A thread grows by one pointer and one byte. The scheduler record of 144 bytes is allocated the first time a thread waits or is detached, so plain coroutines keep their size.

Two findings shaped the code.

- The parts of `resume` that serve detached and waiting coroutines live in functions of their own, out of line (`resumeScheduled`, `passWait`). With them inline, a round trip through a plain coroutine ran 27 more instructions than before, mostly registers saved for paths it never takes. Out of line it runs 2 more, the test for a scheduler record on the way in and on the way out.
- The `Date` header text is cached in the connection. The first version cached it in a thread-local variable with an initial value, which gave the program an initialized thread-local image. Every new thread then copied the whole 256 KB image on its first access to any thread-local variable, and starting a worker took 4 percent longer. With thread-local variables that all start as zeros a new thread gets fresh zero pages.

### The bench suite

`tests/bench/run.sh 9` on the commit before this work and after it, in seconds, with both JIT tiers, with the baseline tier alone, and with the JIT off. The paths of plain calls, leaf natives, and table access are unchanged. Loops that call a Lus function, a native with a frame, and a native with a leaf run the same number of instructions in both builds, to within the 0.3 million instructions that the larger binary adds to the start of the process. `patterns` also runs the same 5.87 billion instructions in both and takes 2 to 3 percent more cycles after, which is the effect of code that moved in the binary. `http_serve` exists only after.

| Benchmark | Before | After | Before, baseline | After, baseline | Before, off | After, off |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arrays` | 0.035 | 0.033 | 0.152 | 0.153 | 0.203 | 0.202 |
| `closures` | 0.063 | 0.065 | 0.073 | 0.073 | 0.076 | 0.075 |
| `data` | 0.026 | 0.026 | 0.032 | 0.033 | 0.032 | 0.033 |
| `fib` | 0.009 | 0.009 | 0.028 | 0.028 | 0.036 | 0.035 |
| `fullgc` | 0.051 | 0.051 | 0.051 | 0.052 | 0.051 | 0.053 |
| `gcpause` | 0.398 | 0.410 | 0.398 | 0.400 | 0.391 | 0.399 |
| `http_serve` | - | 0.666 | - | 0.664 | - | 0.661 |
| `interp` | 0.958 | 0.949 | 0.944 | 0.936 | 0.923 | 0.922 |
| `loop` | 0.059 | 0.058 | 0.143 | 0.144 | 0.213 | 0.215 |
| `messages` | 0.169 | 0.169 | 0.169 | 0.168 | 0.169 | 0.168 |
| `methods` | 0.006 | 0.006 | 0.159 | 0.162 | 0.195 | 0.196 |
| `patterns` | 0.199 | 0.205 | 0.201 | 0.204 | 0.202 | 0.204 |
| `startup` | 0.125 | 0.129 | 0.129 | 0.127 | 0.125 | 0.129 |
| `strings` | 0.150 | 0.150 | 0.147 | 0.147 | 0.142 | 0.145 |
| `tables` | 0.105 | 0.105 | 0.102 | 0.104 | 0.103 | 0.102 |
| `unicode` | 0.007 | 0.007 | 0.029 | 0.029 | 0.032 | 0.033 |

## Later phases

The scheduler is built for more suspension points than the sockets, TLS, `network.fetch`, and the worker mailboxes it has now: name resolution, and SQLite on a thread pool. A TLS session, the decoding of an HTTP body, and the phase that a fetch reached live in the socket, so a native that waits runs again from where it stopped, and a fetch inside a detached coroutine suspends that coroutine alone. A streamed body is a coroutine whose body is a generator native, which each resume runs again for the next part. `network.serve` will gain a `workers` option that shares one port among several states. The Windows poller sends `IOCTL_AFD_POLL` to the AFD driver. The Zig standard library opens each socket on Windows as an AFD endpoint that Winsock never registers, and the driver polls those handles directly. The same request bounds the timeout of a socket when no coroutine is detached. It builds, and it has yet to run on a Windows machine. When the driver refuses a request, the operation blocks in its system call. A send on Windows asks the driver to answer at once, with the flag that Winsock sets for a socket in non-blocking mode, and carries 64 KiB at most, so a large send to a slow reader proceeds in parts between waits. A connect in a state with detached coroutines hands its request to the driver and waits through the scheduler for the event that the driver sets at the end of the request, with a look at that event every 20 ms in case the poll reports the end late. Both paths were checked by reading and by cross-compiling.
