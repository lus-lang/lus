---
name: package.path
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: string
---

The source-module templates used by `require`. Defaults put `.lus` and `init.lus` before the matching `.lua` compatibility templates within each directory. The directories are `share/lus/1.7`, `lib/lus/1.7`, `share/lua/1.7`, `lib/lua/1.7`, then the current directory.

The standalone interpreter derives the prefix from an archive when its executable is under `bin`, then falls back to its configured installation prefix. Embedded states use the prefix configured when `liblus` was built. `LUA_PATH_1_7` takes priority over `LUA_PATH`, and `;;` inserts the defaults at that position.
