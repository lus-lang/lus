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

The logical pipeline is fixed. Every query runs these stages in order:

1. Fetch each source.
2. Join the sources.
3. Filter with `where`.
4. Group with `group by`, then filter groups with `having`.
5. Project with `select`, applying `distinct`.
6. Sort with `order by`.
7. Cut with `limit` and `offset`.

Sources come in three shapes. A plain table serves as an array of records through the built-in in-memory provider. A value whose metatable carries `__query` supplies its own row iterator. Native sources such as [`io.sqlite`](/manual/api#io.sqlite) table references push accepted conjuncts down as parameterized SQL. All providers share the same semantics, so the same query text returns the same rows wherever it runs.

The following example filters an in-memory table and projects one field.

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
