---
name: io.input
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: file
    type: file|string
    optional: true
returns: userdata
---

Sets or returns the default input file, which [`io.read`](/manual/api#io.read) and [`io.lines`](/manual/api#io.lines) read when they get no file.

`file` is optional. A string opens the file of that name in text read mode and makes it the default input. A file handle becomes the default input as it is. Without an argument, the default input stays as it is.

Every form returns the current default input handle after the change. Opening a named file requires `fs:read` for it, and a file that cannot be opened raises an error such as `"PATH: No such file or directory"`. The default input starts as `io.stdin`.

The following example reads the default input from a temporary file and then restores standard input.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-input-example.txt")
io.open(path, "w"):write("first\nsecond\n"):close()
io.input(path)
print(io.read())  --> first
io.input():close()
io.input(io.stdin)
print(io.input() == io.stdin)  --> true
fs.remove(path)
```

Replacing the default input leaves the previous handle open. [`io.output`](/manual/api#io.output) does the same for the default output.
