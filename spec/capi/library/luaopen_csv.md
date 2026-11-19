---
name: luaopen_csv
header: lualib.h
kind: function
since: 1.6.0
stability: stable
origin: lus
signature: "int luaopen_csv (lua_State *L)"
params:
  - name: L
    type: "lua_State*"
returns:
  - type: int
---

Opens the csv library (the global functions `tocsv` and `fromcsv`). Called automatically by `luaL_openlibs`.
