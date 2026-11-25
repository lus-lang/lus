---
name: worker.message
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: value
    type: any
---

Copies `value` into the outbox of the current worker, from which its creator receives it with [`worker.receive`](/manual/api#worker.receive).

`value` is a value of a type that may cross between states, which is `nil`, a boolean, a number, a string, a table, or a vector, as [`worker.send`](/manual/api#worker.send) describes. Any other type raises an error such as `"cannot serialize function to worker"`. The call returns no values and does not wait for the creator. Messages arrive in the order they were sent.

`worker.message` exists only inside a worker. In the main state the field is `nil`, so calling it raises `attempt to call a nil value (field 'message')`.

The following example runs a worker that sends two messages and then ends.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-message.lus")
io.open(path, "w"):write("worker.message('first')\nworker.message({ n = 2 })\n"):close()
local w = worker.create(path)
print(worker.receive(w))  --> first
print(worker.receive(w).n)  --> 2
print(worker.receive(w))  --> nil
fs.remove(path)
```

[`worker.peek`](/manual/api#worker.peek) reads the messages that travel in the other direction.
