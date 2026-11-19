---
name: lua_getlocal
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_getlocal (lua_State *L, const lua_Debug *ar, int n)"
params:
  - name: L
    type: "lua_State*"
  - name: ar
    type: "const lua_Debug*"
  - name: n
    type: int
returns:
  - type: "const char*"
---


