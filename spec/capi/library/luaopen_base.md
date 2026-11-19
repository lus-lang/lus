---
name: luaopen_base
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaopen_base (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the base library. Called automatically by `luaL_openlibs`.
