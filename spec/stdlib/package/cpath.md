---
name: package.cpath
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

The native-module templates used by `require`. Defaults search versioned `lib/lus/1.7` before `lib/lua/1.7`, then the current directory. The standalone interpreter derives the prefix from an archive when its executable is under `bin`, then falls back to its configured installation prefix. Embedded states use the prefix configured when `liblus` was built. `LUA_CPATH_1_7` takes priority over `LUA_CPATH`, and `;;` inserts the defaults at that position.
