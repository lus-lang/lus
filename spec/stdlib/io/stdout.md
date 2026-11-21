---
name: io.stdout
module: io
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: file
---

The standard output stream of the process as a file handle in text write mode.

The handle is open when the program starts, needs no permission, and is the default output that [`io.write`](/manual/api#io.write) writes to until [`io.output`](/manual/api#io.output) changes it. `print` writes to it as well. It accepts the methods of every file handle, such as `write`, `flush`, and `setvbuf`, and `io.stdout:write` returns the handle so that calls can chain. Closing it returns `nil` and `"cannot close standard file"`, and the handle stays open.

```lus
io.stdout:write("hello", ", ", "world", "\n")   --> hello, world
print(io.output() == io.stdout)                 --> true
```

[`io.stderr`](/manual/api#io.stderr) is the standard error, and [`io.stdin`](/manual/api#io.stdin) is the standard input.
