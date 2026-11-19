---
name: luaopen_time
header: lualib.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "int luaopen_time (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the time library. Called automatically by `luaL_openlibs`.
