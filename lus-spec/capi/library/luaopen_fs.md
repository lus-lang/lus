---
name: luaopen_fs
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lus
signature: "int luaopen_fs (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the fs library. Called automatically by `luaL_openlibs`.
