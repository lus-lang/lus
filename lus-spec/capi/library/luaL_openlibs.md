---
name: luaL_openlibs
header: lualib.h
kind: macro
since: 0.1.0
stability: stable
origin: lua
signature: "#define luaL_openlibs(L) luaL_openselectedlibs(L, ~0, 0)"
---

Opens all standard libraries.
