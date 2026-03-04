---
name: luaopen_math
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaopen_math (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the math library. Called automatically by `luaL_openlibs`.
