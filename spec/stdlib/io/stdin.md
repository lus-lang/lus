---
name: io.stdin
module: io
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: file
---

The standard input stream of the process as a file handle in text read mode.

The handle is open when the program starts, needs no permission, and is the default input that [`io.read`](/manual/api#io.read) and [`io.lines`](/manual/api#io.lines) read until [`io.input`](/manual/api#io.input) changes it. It accepts the methods of every file handle, such as `read` and `lines`, and validates what it reads as UTF-8. Closing it returns `nil` and `"cannot close standard file"`, and the handle stays open.

```lus
print(io.type(io.stdin))          --> file
print(io.input() == io.stdin)     --> true
```

[`io.stdout`](/manual/api#io.stdout) is the standard output, and [`io.stderr`](/manual/api#io.stderr) is the standard error.
