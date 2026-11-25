---
name: dofile
module: base
kind: function
since: 0.1.0
stability: stable
pledges: ["load", "fs:read"]
origin: lua
params:
  - name: filename
    type: string
returns: any
---

`dofile(filename)` compiles the file `filename` as a Lus chunk, runs it, and returns every value the chunk returns.

The parameter `filename` is the path of a source or binary chunk, relative to the working directory or absolute. The chunk runs with no arguments, in the global environment.

`dofile` requires the `load` permission and `fs:read` for `filename`. A missing permission raises `permission "load" denied` or `permission "fs:read" denied for 'PATH'`. A file that cannot be read raises `cannot open PATH (REASON)`, a syntax error in the file raises that error, and an error raised by the chunk propagates to the caller. A missing `filename` raises `bad argument #1 to 'dofile' (string expected, got no value)`.

```lus
pledge("fs", "load")
local path = os.tmpname()
local f = assert(io.open(path, "w"))
f:write('print("running")\nreturn 1, 2\n')
f:close()
print(dofile(path))  --> running
--> 1  2
fs.remove(path)
```

The chunk name is `@` followed by `filename`, so errors inside the chunk name the file. [`loadfile`](/manual/api#loadfile) compiles a file without running it and returns failures as values, and [`require`](/manual/api#require) loads a module once and caches it.
