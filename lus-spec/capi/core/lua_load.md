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


