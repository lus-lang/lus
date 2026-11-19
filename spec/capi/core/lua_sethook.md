---
name: lua_sethook
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "void lua_sethook (lua_State *L, lua_Hook func, int mask, int count)"
params:
  - name: L
    type: "lua_State*"
  - name: func
    type: lua_Hook
  - name: mask
    type: int
  - name: count
    type: int
---


