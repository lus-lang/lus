---
name: luaopen_network
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int luaopen_network (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the network library. Called automatically by `luaL_openlibs`.
