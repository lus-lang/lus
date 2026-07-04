---
name: luaopen_query
header: lualib.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "int luaopen_query (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the query library. Called automatically by `luaL_openlibs`.
