---
name: luaL_loadbufferx
header: lauxlib.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int luaL_loadbufferx (lua_State *L, const char *buff, size_t sz, const char *name, const char *mode)"
params:
  - name: L
    type: "lua_State*"
  - name: buff
    type: "const char*"
  - name: sz
    type: size_t
  - name: name
    type: "const char*"
  - name: mode
    type: "const char*"
returns:
  - type: int
---


