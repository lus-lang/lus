---
name: luaL_openselectedlibs
header: lualib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void luaL_openselectedlibs (lua_State *L, int load, int preload)"
params:
  - name: L
    type: "lua_State*"
  - name: load
    type: int
  - name: preload
    type: int
---

Opens selected standard libraries. The `load` and `preload` bitmasks control which libraries to open or preload.
