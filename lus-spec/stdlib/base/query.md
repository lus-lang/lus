---
name: query
module: base
kind: function
since: 1.7.0
stability: unstable
origin: lus
params:
  - name: q
    type: query
returns: function
---

Evaluates the query `q` and returns a fresh iterator over its result records, for use in a generic `for`. Each call to `query(q)` runs the query again, so a stored query value observes source changes on its next loop. Every result is a record: a projected field table, or the source row itself for a whole-row projection.

The logical pipeline is fixed: fetch each source, join, `where`, `group by`, `having`, `select` and `distinct`, `order by`, then `limit` and `offset`. A plain table serves as an array of records through the built-in in-memory provider, a value whose metatable carries `__query` supplies its own row iterator, and native sources such as [`io.sqlite`](/manual/api#io.sqlite) table references push accepted conjuncts down as parameterized SQL. All providers share the same semantics, so the same query text returns the same rows wherever it runs.

```lus
global query, print

local people = {
    { name = "Alice", age = 30 },
    { name = "Bob",   age = 17 },
}

for row in query(@people as p where p.age >= 18 select p.name) do
    print(row.name)
end
```
