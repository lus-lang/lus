---
name: lus_tosqlite
header: lua.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "void *lus_tosqlite (lua_State *L, int idx)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
---

Returns the underlying `sqlite3*` connection of the open `io.sqlite` database handle at `idx`, or `NULL` when the handle is closed or the value is not a database handle. The returned pointer stays owned by the handle, so an embedder must not close it and must not use it after the handle closes or is collected. The vendored `sqlite3.h` matching the embedded SQLite is installed alongside the Lus headers. Builds compiled with `LUS_NO_SQLITE` omit the symbol entirely.
