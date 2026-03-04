---
name: luaopen_utf8
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaopen_utf8 (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the utf8 library. Called automatically by `luaL_openlibs`.
