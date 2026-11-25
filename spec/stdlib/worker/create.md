---
name: worker.create
module: worker
kind: function
since: 0.1.0
stability: stable
pledges: ["load", "fs:read"]
origin: lus
params:
  - name: path
    type: string
vararg: true
returns: worker
---

Starts a worker that runs the script at `path` in a state of its own and returns a handle to it.

`path` is the string path of a Lus script. The extra arguments are copied into the new state and become the values of `...` in the script. They may be `nil`, booleans, numbers, strings, tables, and vectors, as [`worker.send`](/manual/api#worker.send) describes, and any other value raises an error such as `"cannot serialize function to worker"`.

On success the call returns one worker handle, which [`worker.receive`](/manual/api#worker.receive), [`worker.send`](/manual/api#worker.send), and [`worker.status`](/manual/api#worker.status) take. The call requires the `load` permission and `fs:read` for `path`, and a missing permission raises an error such as `permission "load" denied`. A script that cannot be read still returns a handle. The worker then fails, and the first `worker.receive` on it raises `"cannot open worker script 'PATH': REASON"`.

The worker runs in parallel with its creator. It runs its script and then the coroutines that the script detached, as `lus` does for a program, and it ends when the last of them has ended. It starts with a sealed copy of the permissions of its creator, so every `pledge` inside it returns `false`.

The following example writes a worker script to a temporary file, starts it with two arguments, and receives their sum.

```lus
pledge("env", "fs", "load")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-worker-create.lus")
io.open(path, "w"):write("local a, b = ...\nworker.message(a + b)\n"):close()
local w = worker.create(path, 2, 40)
print(worker.receive(w))  --> 42
fs.remove(path)
```

The WebAssembly build of Lus leaves the worker library out.
