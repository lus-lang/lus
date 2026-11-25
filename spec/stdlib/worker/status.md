---
name: worker.status
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w
    type: worker
returns: string
---

Returns `"running"` while the worker `w` runs and `"dead"` after it has finished or failed.

`w` is a worker handle, and any other value raises `bad argument #1 to 'status' (worker expected, got TYPE)`. A worker counts as running until its script and the coroutines that the script detached have ended. A worker whose script could not be read may report `"running"` until it has failed. The function requires no permission and never waits.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-status.lus")
io.open(path, "w"):write("worker.message(worker.peek())\n"):close()
local w = worker.create(path)
print(worker.status(w))  --> running
worker.send(w, "go")
print(worker.receive(w))  --> go
print(worker.receive(w))  --> nil
print(worker.status(w))  --> dead
fs.remove(path)
```

[`worker.receive`](/manual/api#worker.receive) returns `nil` for a worker that has ended with no message left.
