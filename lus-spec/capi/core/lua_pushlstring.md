---
name: lua_pushlstring
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_pushlstring (lua_State *L, const char *s, size_t len)"
params:
  - name: L
    type: "lua_State*"
  - name: s
    type: "const char*"
  - name: len
    type: size_t
returns:
  - type: "const char*"
---


