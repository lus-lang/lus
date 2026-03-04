---
name: lua_Debug
header: lua.h
kind: type
since: 0.1.0
stability: stable
origin: lua
signature: "struct lua_Debug { int event; const char *name; const char *namewhat; const char *what; const char *source; size_t srclen; int currentline; int linedefined; int lastlinedefined; unsigned char nups; unsigned char nparams; char isvararg; unsigned char extraargs; char istailcall; int ftransfer; int ntransfer; char short_src[LUA_IDSIZE]; };"
---

A structure used to carry different pieces of information about a function or an activation record.
