---
name: luaopen_io
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaopen_io (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the io library. Called automatically by `luaL_openlibs`.
