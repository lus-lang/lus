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

Registers the native query provider `p` on the metatable at `mt_idx`, so every value carrying that metatable becomes a query source served by `p`. The provider struct holds two callbacks. `accepts(L, q, n)` is consulted once per single-source, closure-free `where` conjunct and returns 1 to claim it. `open(L, q, srcindex, pushed, npushed)` receives the claimed conjunct nodes and must push a row iterator function; the engine drains it and never evaluates the claimed conjuncts in memory again. The struct must stay alive for the lifetime of the state, so a `static const` definition is the usual shape.
