---
name: debug.queryplan
module: debug
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: q
    type: query
returns: string
---

Renders the execution plan of the query `q` as a human-readable string without running it: each source with its provider (in-memory, `__query`, or native) and the number of conjuncts pushed down to it, followed by the disposition of every `where` conjunct (pushed down, in memory as a host closure, or in memory as a translatable expression). The string gives tests and programs a direct observable for push-down decisions.
