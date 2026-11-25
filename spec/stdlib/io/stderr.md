---
name: io.stderr
module: io
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: file
---

The standard error stream of the process as a file handle in text write mode.

The handle is open when the program starts and needs no permission. It accepts the methods of every file handle, such as `write` and `flush`, and `io.stderr:write` returns the handle so that calls can chain. Closing it returns `nil` and `"cannot close standard file"`, and the handle stays open.

```lus
print(io.stderr:write("") == io.stderr)  --> true
print(io.type(io.stderr))  --> file
```

[`io.stdout`](/manual/api#io.stdout) is the standard output, and [`io.stdin`](/manual/api#io.stdin) is the standard input.
