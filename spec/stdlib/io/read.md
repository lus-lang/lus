---
name: io.read
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
vararg: true
returns: string|vector|nil
---

Reads from the default input file according to the given formats and returns one value per format.

Each argument is a format. `"l"`, the default, reads one line and drops its newline. `"L"` reads one line and keeps its newline. `"a"` reads the rest of the file. `"n"` reads a number, written in decimal or hexadecimal. An integer `n` reads up to `n` characters, and `0` reads nothing and tests for the end of the file. Any other format raises a `bad argument` error.

The call returns one value per format. A format that finds nothing returns `nil` at the end of the file, and reading stops at the first format that fails, so the later formats return nothing. `"a"` returns the empty string at the end of the file, and `0` returns the empty string before it. The default input starts as `io.stdin` in text mode, so the results are strings. `io.read` requires no permission, since the default input is already open.

The following example points the default input at a temporary file and reads it with several formats.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-read-example.txt")
io.open(path, "w"):write("0x10 3.5 rest\nlast line\n"):close()
io.input(path)
print(io.read("n", "n"))                 --> 16  3.5
print(io.read("l"))                      -->  rest
print(io.read("L") == "last line\n")     --> true
print(io.read("l"))                      --> nil
io.input():close()
fs.remove(path)
```

On a file handle opened in binary mode, `file:read` takes the same formats and returns vectors, and an integer counts bytes. A text file validates what it reads as UTF-8, as [`io.open`](/manual/api#io.open) describes. [`io.input`](/manual/api#io.input) sets the default input, and [`io.lines`](/manual/api#io.lines) reads in a loop.
