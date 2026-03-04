---
name: luaopen_coroutine
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaopen_coroutine (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the coroutine library. Called automatically by `luaL_openlibs`.
