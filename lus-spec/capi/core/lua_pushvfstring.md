---
name: lua_pushvfstring
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "const char *lua_pushvfstring (lua_State *L, const char *fmt, va_list argp)"
params:
  - name: L
    type: "lua_State*"
  - name: fmt
    type: "const char*"
  - name: argp
    type: va_list
returns:
  - type: "const char*"
---


