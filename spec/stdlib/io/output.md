---
name: io.output
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

Sets or returns the default output file, which [`io.write`](/manual/api#io.write) writes to.

`file` is optional. A string opens the file of that name in write mode, which empties an existing file, and makes it the default output. A file handle becomes the default output as it is. Without an argument, the default output stays as it is.

Every form returns the current default output handle after the change. Opening a named file requires `fs:write` for it, and a file that cannot be opened raises an error. The default output starts as `io.stdout`.

The following example sends [`io.write`](/manual/api#io.write) to a temporary file, then restores standard output and reads the file back.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-output-example.txt")
io.output(path)
io.write("to the file")
io.close()
io.output(io.stdout)
print(io.open(path):read("a"))   --> to the file
fs.remove(path)
```

Replacing the default output leaves the previous handle open, so the example closes it with [`io.close`](/manual/api#io.close) first. [`io.input`](/manual/api#io.input) does the same for the default input.
