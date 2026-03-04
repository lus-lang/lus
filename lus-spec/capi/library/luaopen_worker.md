---
name: luaopen_worker
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int luaopen_worker (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the worker library. Called automatically by `luaL_openlibs`.
