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


