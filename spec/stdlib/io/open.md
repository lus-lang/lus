---
name: io.open
module: io
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:read", "fs:write"]
origin: lua
params:
  - name: filename
    type: string
  - name: mode
    type: string
    optional: true
  - name: options
    type: table
    optional: true
returns: userdata|nil
---

Opens the file `filename` in the given `mode` and returns a file handle, or `nil` and an error message when the file cannot be opened.

`filename` is the string path of the file. `mode` is a string that defaults to `"r"`. It follows C `fopen` conventions: `"r"` reads, `"w"` writes and empties an existing file, and `"a"` appends. A `"+"` after the letter opens the file for both reading and writing, and a trailing `"b"` opens it in binary mode, as in `"r+b"`. Any other mode, such as `"rw"`, `"rb+"`, or the empty string, raises a `bad argument` error. The optional `options` table takes the boolean field `lossy`, which defaults to `false`.

On success the call returns one file handle. When the operating system refuses to open the file, the call returns three values: `nil`, a message of the form `"PATH: REASON"` such as `"missing.txt: No such file or directory"`, and the number `2`, which the runtime returns for every reason. A mode that reads, which is `"r"` or any mode with `"+"`, requires `fs:read` for `filename`, and a mode that writes, which is `"w"`, `"a"`, or any mode with `"+"`, requires `fs:write`. A missing permission raises an error.

A file opened in text mode reads strings and validates them as UTF-8. A read that meets an invalid sequence raises an error that names its byte offset, and `lossy` set to `true` replaces each invalid sequence with U+FFFD instead. A file opened in binary mode reads vectors of raw bytes. Writing accepts strings, numbers, and vectors in either mode.

The following example writes a temporary file, reads it back, and shows the result of opening a missing file.

```lus
pledge("env", "fs")
local path = fs.path.join(os.getenv("TMPDIR") or "/tmp", "lus-open-example.txt")
local out = io.open(path, "w")
out:write("count: ", 2)
out:close()
print(io.open(path):read("a"))  --> count: 2
local file, err = io.open(path .. ".missing")
print(file, err:match("No such file or directory"))  --> nil  No such file or directory
fs.remove(path)
```

A directory opens in read mode, and the first read from it raises an error that ends in `Is a directory`. A handle declared with the `<close>` attribute closes when its variable goes out of scope. [`io.lines`](/manual/api#io.lines) opens a file for a loop, [`io.tmpfile`](/manual/api#io.tmpfile) opens an anonymous temporary file, and [`io.sqlite`](/manual/api#io.sqlite) opens a database.
