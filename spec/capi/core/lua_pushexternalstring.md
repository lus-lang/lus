---
name: lua_pushexternalstring
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_pushexternalstring (lua_State *L, const char *s, size_t len, lua_Alloc falloc, void *ud)"
params:
  - name: L
    type: "lua_State*"
  - name: s
    type: "const char*"
  - name: len
    type: size_t
  - name: falloc
    type: lua_Alloc
  - name: ud
    type: "void*"
returns:
  - type: "const char*"
---


