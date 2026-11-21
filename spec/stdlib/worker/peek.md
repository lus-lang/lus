---
name: worker.peek
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
returns: any
---

Waits for the next value that the creator sent to the current worker with [`worker.send`](/manual/api#worker.send), and returns a copy of it.

The function takes no arguments. Values arrive in the order they were sent, and each call takes one of them. When the inbox is empty, the call waits until a value arrives.

`worker.peek` exists only inside a worker. In the main state the field is `nil`, so calling it raises `attempt to call a nil value (field 'peek')`.

`peek` is a suspension point. Inside a detached coroutine it suspends the coroutine while it waits, and anywhere else the detached coroutines of the worker run while it waits (see `coroutine.detach`).

The following example sends a worker a number and receives the doubled value back.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-peek.lus")
io.open(path, "w"):write("worker.message(worker.peek() * 2)\n"):close()
local w = worker.create(path)
worker.send(w, 21)
print(worker.receive(w))   --> 42
fs.remove(path)
```

[`worker.message`](/manual/api#worker.message) sends values from the worker to its creator.
