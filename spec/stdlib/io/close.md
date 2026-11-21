---
name: io.close
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: file
    type: file
    optional: true
returns: boolean|nil
---

Closes `file`, or the default output file when no argument is given, and returns the status of the close.

`file` is an open file handle. It defaults to the current default output, which [`io.output`](/manual/api#io.output) sets.

Closing a file returns `true`. Closing a handle from [`io.popen`](/manual/api#io.popen) waits for the program to exit and returns the same three values as [`os.execute`](/manual/api#os.execute): `true` or `nil`, then `"exit"` or `"signal"`, then the exit status or signal number. The standard files stay open, and closing one returns `nil` and the message `"cannot close standard file"`, which is also what a bare `io.close()` returns while the default output is `io.stdout`. Closing a handle that is already closed raises the error `"attempt to use a closed file"`. `io.close` itself requires no permission.

The following example closes a file and then inspects the closed handle.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-close-example.txt")
local file = io.open(path, "w")
print(io.close(file))          --> true
print(io.type(file))           --> closed file
print(io.close(io.stdout))     --> nil  cannot close standard file
fs.remove(path)
```

`file:close()` does the same for one handle. A handle declared with the `<close>` attribute closes when its variable goes out of scope, and the collector closes a handle that nothing refers to any more.
