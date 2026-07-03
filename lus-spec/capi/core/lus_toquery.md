---
name: lus_toquery
header: lua.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "lus_Query *lus_toquery (lua_State *L, int idx)"
params:
  - name: L
    type: "lua_State*"
  - name: idx
    type: int
---

Returns the query value at `idx` as an opaque `lus_Query*`, or `NULL` when the value is not a query. The pointer stays owned by the Lua state and is valid while the query value is reachable. It is the entry point to the query visitor: `lus_querysourcecount`, `lus_querysourcealias`, and `lus_querysource` read the sources, `lus_queryclausecount` and `lus_queryclause` reach each clause's reified nodes (using the `LUS_QWHERE` through `LUS_QOFFSET` clause identifiers, with `lus_queryselectname`, `lus_queryorderdesc`, and `lus_querydistinct` for the clause details), and `lus_qnodekind`, `lus_qnodeop`, `lus_qnodechild`, `lus_qnodename`, and `lus_qnodevalue` walk the expression nodes down to captured parameter and closure values.
