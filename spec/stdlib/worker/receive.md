---
name: worker.receive
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w1
    type: worker
vararg: true
returns: any
---

Waits until at least one of the given workers has a message or has ended, then returns one value per worker.

Each argument is a worker handle from [`worker.create`](/manual/api#worker.create), and at least one is required. A call without arguments raises `"expected at least one worker"`.

The call returns one value per argument, in the order of the arguments. A worker with a ready message contributes a copy of that message, and a worker without one contributes `nil`. A worker that has ended and has no message left contributes `nil`, so a single-handle call returns `nil` once the worker is done. An error that ended the script of a worker is raised once the messages it sent before the error have been received, by this call and by every later `receive` on that handle. A string error arrives as it is. Any other error value arrives as a copy when it is a value that may cross between states, as [`worker.send`](/manual/api#worker.send) describes, so a table raised in a worker arrives as a table, and otherwise it arrives as its string form. The function requires no permission.

A worker ends once its script has returned and the coroutines that the script detached have ended (see `coroutine.detach`). The error of a detached coroutine that failed with nothing left to collect it is the error of the worker, and it propagates from this call like a script error.

`receive` is a suspension point. Inside a detached coroutine it suspends the coroutine while it waits, and anywhere else the detached coroutines of the state run while it waits.

The following example receives a message from a worker, then catches the error that ended it.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-receive.lus")
io.open(path, "w"):write("worker.message('working')\nerror('worker broke', 0)\n"):close()
local w = worker.create(path)
print(worker.receive(w))           --> working
print(catch worker.receive(w))     --> false  worker broke
print(worker.status(w))            --> dead
fs.remove(path)
```

[`worker.message`](/manual/api#worker.message) sends the messages that `receive` returns, and [`worker.status`](/manual/api#worker.status) tells whether a worker still runs.
