---
name: lua_dump
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_dump (lua_State *L, lua_Writer writer, void *data, int strip)"
params:
  - name: L
    type: "lua_State*"
  - name: writer
    type: lua_Writer
  - name: data
    type: "void*"
  - name: strip
    type: int
returns:
  - type: int
---

Writes the binary representation of the function at the top of the stack through `writer`. A nonzero `strip` omits debug information. The output is a version-dependent artifact for a trusted build or storage path.
