---
name: lua_setupvalue
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_setupvalue (lua_State *L, int funcindex, int n)"
params:
  - name: L
    type: "lua_State*"
  - name: funcindex
    type: int
  - name: n
    type: int
returns:
  - type: "const char*"
---


