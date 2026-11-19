---
name: luaL_prepbuffer
header: lauxlib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_prepbuffer(B) luaL_prepbuffsize(B, LUAL_BUFFERSIZE)"
---

Equivalent to `luaL_prepbuffsize` with `LUAL_BUFFERSIZE`.
