---
name: worker.send
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: w
    type: worker
  - name: value
    type: any
---

Copies `value` into the inbox of the worker `w`, from which the worker takes it with [`worker.peek`](/manual/api#worker.peek).

`w` is a worker handle, and `value` is the value to send. The call returns no values and does not wait for the worker. Sending to a worker that has ended succeeds and the value is never read.

`nil`, booleans, numbers of every subtype, strings, tables, and vectors may cross between states. Every other type, such as functions, coroutines, userdata, enum values, and queries, raises an error such as `"cannot serialize function to worker"`. A table arrives as a copy that keeps its shape, so shared references and cycles survive, and metatables stay behind. Tables may nest up to 100 levels, and a deeper table raises `"table nesting too deep for serialization"`. A vector moves to the receiver. The receiver takes over its bytes, the vector of the sender becomes empty, and sending it again raises `"cannot send a vector that was transferred to another worker"`. The function requires no permission.

The following example sends a table to a worker and receives an answer computed from it.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-send.lus")
io.open(path, "w"):write("local t = worker.peek()\nworker.message(#t.items)\n"):close()
local w = worker.create(path)
worker.send(w, { items = { "a", "b", "c" } })
print(worker.receive(w))   --> 3
fs.remove(path)
```

[`worker.message`](/manual/api#worker.message) sends values in the other direction.
