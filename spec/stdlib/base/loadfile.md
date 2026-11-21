---
name: loadfile
module: base
kind: function
since: 0.1.0
stability: stable
pledges: ["load", "fs:read"]
origin: lua
params:
  - name: filename
    type: string
  - name: mode
    type: string
    optional: true
  - name: env
    type: table
    optional: true
returns: function|nil
---

`loadfile(filename, mode, env)` compiles the file `filename` as a Lus chunk without running it and returns the chunk as a function, or `nil` and an error message on failure.

The parameters refine the load:

- `filename` is the path of the file, relative to the working directory or absolute.
- `mode` sets which chunks are accepted: `"t"` for source text, `"b"` for binary chunks, and `"bt"` for both. The default is `"bt"`.
- `env`, when given, becomes the first upvalue of the chunk, which is its `_ENV`. Without it the chunk uses the global environment.

On success, `loadfile` returns one function, which runs the chunk when called and passes its arguments to the chunk as `...`. On failure it returns `nil` and a message. The failures are a file that cannot be read, with the message `cannot open PATH (REASON)`, a syntax error, and a chunk that `mode` rejects, with the message `attempt to load a text chunk (mode is 'b')` or its binary counterpart.

`loadfile` requires the `load` permission and `fs:read` for `filename`, and raises `permission "load" denied` or `permission "fs:read" denied for 'PATH'` when one is missing. A missing `filename` raises `bad argument #1 to 'loadfile' (string expected, got no value)`.

```lus
pledge("fs", "load")
local path = os.tmpname()
local f = assert(io.open(path, "w"))
f:write("return greeting .. ', ' .. ...")
f:close()
local chunk = loadfile(path, "t", { greeting = "hello" })
print(chunk("world"))   --> hello, world
fs.remove(path)
```

The chunk name is `@` followed by `filename`, so errors inside the chunk name the file. Binary chunks are version-dependent artifacts for trusted build and storage paths. Treat every binary chunk as trusted input, and use `mode = "t"` for a file supplied across an untrusted boundary. [`load`](/manual/api#load) compiles a string, a vector, or the pieces of a reader function, and [`dofile`](/manual/api#dofile) compiles and runs a file in one call.
