---
name: load
module: base
kind: function
since: 0.1.0
stability: stable
pledges: ["load"]
origin: lua
params:
  - name: chunk
    type: string|vector|function
  - name: chunkname
    type: string
    optional: true
  - name: mode
    type: string
    optional: true
  - name: env
    type: table
    optional: true
returns: function|nil
---

`load(chunk, chunkname, mode, env)` compiles a chunk without running it and returns the chunk as a function, or `nil` and an error message on failure.

The parameters refine the load:

- `chunk` is the code. A string holds source text or a binary chunk. A vector holds the bytes of a binary chunk, which is the form [`string.dump`](/manual/api#string.dump) produces. A function is a reader that `load` calls repeatedly, and the pieces it returns are joined until it returns `nil` or the empty string.
- `chunkname` names the chunk in error messages and tracebacks. It defaults to the source string itself for a string chunk and to `"=(load)"` otherwise.
- `mode` sets which chunks are accepted: `"t"` for source text, `"b"` for binary chunks, and `"bt"` for both. The default is `"bt"`.
- `env`, when given, becomes the first upvalue of the chunk, which is its `_ENV`. Without it the chunk uses the global environment.

On success, `load` returns one function, which runs the chunk when called and passes its arguments to the chunk as `...`. On failure it returns `nil` and a message. The failures are a syntax error, a chunk that `mode` rejects, with the message `attempt to load a text chunk (mode is 'b')` or its binary counterpart, a reader that raises an error, and a reader that returns a value other than a string, with the message `reader function must return a string`.

`load` requires the `load` permission and raises `permission "load" denied` without it. A `chunk` of another type raises `bad argument #1 to 'load' (string expected, got TYPE)`.

```lus
pledge("load")
local add = load("local a, b = ... return a + b")
print(add(2, 3))                                  --> 5
print(load("return x * 2", "=calc", "t", { x = 21 })())   --> 42
print(load("return +", "=bad"))   --> nil  bad:1: unexpected symbol near '+'
```

Binary chunks are version-dependent artifacts for trusted build and storage paths. Treat every binary chunk as trusted input, and use `mode = "t"` when the chunk source crosses an untrusted boundary. [`loadfile`](/manual/api#loadfile) compiles a file, and [`dofile`](/manual/api#dofile) compiles and runs one.
