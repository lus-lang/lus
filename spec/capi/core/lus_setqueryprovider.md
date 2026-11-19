---
name: lus_setqueryprovider
header: lua.h
kind: function
since: 1.7.0
stability: unstable
origin: lus
signature: "void lus_setqueryprovider (lua_State *L, int mt_idx, const lus_QueryProvider *p)"
params:
  - name: L
    type: "lua_State*"
  - name: mt_idx
    type: int
  - name: p
    type: "const lus_QueryProvider*"
---

Registers the native query provider `p` on the metatable at `mt_idx`, so values carrying that metatable become query sources served by `p`. Passing `NULL` unregisters the provider.

The metatable borrows the `lus_QueryProvider` pointer and does not copy or free it. Keep the struct alive until it is unregistered, the metatable becomes unreachable, or the state closes. A `static const` provider is a typical lifetime match.

`accepts(L, q, n)` is consulted once per single-source, closure-free `where` conjunct and returns `1` to claim it. `open(L, q, srcindex, pushed, npushed)` receives the claimed conjunct nodes and pushes a row iterator function. The engine drains that iterator and does not evaluate claimed conjuncts again in memory.

The callback arguments are borrowed and read-only. The `pushed` array and its node pointers are valid only for the `open` call. Query-owned pointers remain valid while their query value is reachable, as described by `lus_toquery`. Copy any names or other data that must outlive the callback.
