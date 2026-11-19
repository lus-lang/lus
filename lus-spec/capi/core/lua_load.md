---
name: lua_load
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_load (lua_State *L, lua_Reader reader, void *dt, const char *chunkname, const char *mode)"
params:
  - name: L
    type: "lua_State*"
  - name: reader
    type: lua_Reader
  - name: dt
    type: "void*"
  - name: chunkname
    type: "const char*"
  - name: mode
    type: "const char*"
returns:
  - type: int
---

Loads a text or binary chunk supplied by `reader`, using `mode` to select `"t"`, `"b"`, or both. On success it pushes the compiled function and returns `LUA_OK`. A syntax, format, or memory failure returns the corresponding status with an error object on the stack.

Binary chunks are version-dependent artifacts for trusted build and storage paths. Treat every binary chunk as trusted input. Use `mode = "t"` when the reader crosses an untrusted boundary.
