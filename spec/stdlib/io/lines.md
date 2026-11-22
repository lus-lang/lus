---
name: io.lines
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read"]
origin: lua
params:
  - name: filename
    type: string
    optional: true
vararg: true
returns: function
---

Returns an iterator that reads the file `filename`, or the default input, with the given formats on every call.

`filename` is optional. With it, the file is opened in text read mode, and the call requires `fs:read` for it. Without it, the iterator reads the default input that [`io.input`](/manual/api#io.input) sets. The formats after `filename` are those of [`io.read`](/manual/api#io.read) and default to `"l"`, which reads one line without its newline. Each call of the iterator returns one value per format.

The call returns four values for a generic `for`: the iterator, two `nil` values, and the file handle as the closing value, so a loop that ends early, or that raises an error, still closes the file. The iterator returns `nil` at the end of the file and closes the file then, including the default input. Calling the iterator again after that raises `"file is already closed"`. A file that cannot be opened raises an error such as `"PATH: No such file or directory"`. An invalid format raises a `bad argument` error at the first call of the iterator. A read that the operating system refuses raises its message from the iterator, as Lua's `io.lines` does, so a `for` loop stops with that error and closes the file through its closing value. `file:lines` raises in the same way. A program that must continue after such a failure reads with `file:read`, which returns the error as [`io.read`](/manual/api#io.read) describes.

The following example reads a temporary file line by line, then reads it with two formats per step.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-lines-example.txt")
io.open(path, "w"):write("10 apples\n20 pears\n"):close()
local lines = {}
for line in io.lines(path) do lines[#lines + 1] = line end
print(table.concat(lines, ", "))   --> 10 apples, 20 pears
local total = 0
for count in io.lines(path, "n", "l") do total = total + count end
print(total)                       --> 30
fs.remove(path)
```

A file opened in text mode validates every line as UTF-8, as [`io.open`](/manual/api#io.open) describes. `file:lines(...)` reads an open handle the same way, with one difference: it returns only the iterator and leaves the file open at the end of the input, as in Lua, so the program that opened the file closes it.
