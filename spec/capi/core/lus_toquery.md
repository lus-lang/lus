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

Returns the query value at `idx` as a borrowed opaque `lus_Query*`, or `NULL` when the value is not a query. The Lua state owns the pointer, and it remains valid while the query value is reachable.

This pointer is the entry point to the read-only query visitor. `lus_querysourcecount`, `lus_querysourcealias`, and `lus_querysource` read the sources. `lus_queryclausecount` and `lus_queryclause` reach each clause's reified nodes through the `LUS_QWHERE` to `LUS_QOFFSET` clause identifiers. `lus_queryselectname`, `lus_queryorderdesc`, and `lus_querydistinct` expose clause details. `lus_qnodekind`, `lus_qnodeop`, `lus_qnodechild`, `lus_qnodename`, and `lus_qnodevalue` walk expression nodes down to captured parameter and closure values.

Visitor-returned query nodes and name pointers are also borrowed from the query. Copy data that must outlive the reachable query value. Functions that push sources or captured values follow normal stack ownership rules.
