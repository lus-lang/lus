---
name: lua_pcallk
header: lua.h
kind: function
since: 0.1.0
stability: stable
origin: lua
signature: "int lua_pcallk (lua_State *L, int nargs, int nresults, int errfunc, lua_KContext ctx, lua_KFunction k)"
params:
  - name: L
    type: "lua_State*"
  - name: nargs
    type: int
  - name: nresults
    type: int
  - name: errfunc
    type: int
  - name: ctx
    type: lua_KContext
  - name: k
    type: lua_KFunction
returns:
  - type: int
---

Calls a function in protected mode with continuation support. Success returns `LUA_OK`. A failure returns its status code and leaves the error object on the stack. When the call yields, `k` continues it with context `ctx`.
