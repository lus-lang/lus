---
name: lua_resume
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_resume (lua_State *L, lua_State *from, int narg, int *nres)"
params:
  - name: L
    type: "lua_State*"
  - name: from
    type: "lua_State*"
  - name: narg
    type: int
  - name: nres
    type: "int*"
returns:
  - type: int
---


