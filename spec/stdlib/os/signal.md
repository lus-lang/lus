---
name: os.signal
module: os
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: name
    type: string
  - name: ...
    type: string
    optional: true
returns: thread
---

Starts handling the named signals and returns a coroutine that hands them over, one per resume.

Each argument names a signal.

- `"interrupt"` is SIGINT, which Ctrl-C sends from a terminal. On Windows it is the Ctrl-C and Ctrl-Break events of the console.
- `"terminate"` is SIGTERM, which service managers and `kill` send to stop a program. On Windows it is the close, logoff, and shutdown events of the console.
- `"hangup"` is SIGHUP. Windows has no such signal, and the name raises an error there.

While a coroutine of `os.signal` handles a signal, the signal no longer ends the program. Resuming the coroutine waits until one of its signals arrives, then returns `true` and the name of the signal. Each signal that arrives after the call is counted, so a signal that arrives while the program does other work is returned by the next resume. The system itself merges a signal into one that is still pending, so two identical signals sent at the same moment may arrive as one. Resumed from a detached coroutine, the wait suspends that coroutine, and resumed anywhere else it blocks while the detached coroutines run.

When an interrupt was returned and a second interrupt arrives before any coroutine waits for interrupts again, the program ends at once with exit status 130. A program whose shutdown hangs therefore still stops on the second Ctrl-C.

Closing the coroutine with `coroutine.close` stops handling its signals, as does the collection of a coroutine that nothing references. A signal that no other coroutine handles then gets the action it had before the call, which for these signals ends the program. Several coroutines may handle the same signal, and every one of them receives it.

On Windows a close, logoff, or shutdown event ends the process as soon as its handler returns, so the runtime holds the event until the process ends by itself or until the system ends it, about five seconds later.

A call without arguments, or with a name that is not one of the three, raises a bad argument error. The call needs no permission, because handling a signal changes only how the program itself ends.

The following program serves HTTP until it receives SIGTERM or Ctrl-C. Closing the coroutine that runs `network.serve` lets the requests in progress finish before the program ends.

```lus nocheck
pledge("network:server=127.0.0.1:8080")
local serving = coroutine.detach(coroutine.create(network.serve), "127.0.0.1", 8080, function(req)
    return 200, "hello"
end)
local stop = os.signal("interrupt", "terminate")
local _, name = coroutine.resume(stop)
print("stopping on " .. name)
coroutine.close(serving)
```

[`os.spawn`](/manual/api#os.spawn) sends signals to other processes with `p:kill`.
