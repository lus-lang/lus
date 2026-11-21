---
name: io.write
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: userdata|nil
---

Writes each argument to the default output file and returns that file handle.

Each argument is a string, a number, or a vector. A number is written in the form that `tostring` gives it, and a vector is written as its raw bytes. Any other value raises a `bad argument` error naming its position, such as `bad argument #1 to 'write' (string expected, got table)`. The call adds no separators and no newline.

On success the call returns the default output handle, so that calls can chain. A write that the operating system refuses returns `nil` and an error message. `io.write` requires no permission, since the default output is already open.

```lus
io.write("pi is about ", 3.14, "\n")         --> pi is about 3.14
print(io.write("") == io.stdout)             --> true
```

The default output starts as `io.stdout`, and [`io.output`](/manual/api#io.output) changes it. `file:write` writes to one handle, and `print` writes its arguments with tabs and a newline.
