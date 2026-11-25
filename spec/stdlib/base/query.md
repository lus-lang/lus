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

`query(q)` evaluates the query value `q` and returns a fresh iterator over its result records, for use in a generic `for`.

The parameter `q` is a query value, built with an `@` query expression. Any other value raises `bad argument #1 to 'query' (query expected, got TYPE)`.

Each call to `query(q)` runs the query again, so a stored query value observes changes to its sources on its next loop. Every result is a record: a table of the projected fields, or the source row itself for a query without `select`.

The logical pipeline is fixed. Every query runs these stages in order:

1. Fetch each source.
2. Join the sources.
3. Filter with `where`.
4. Group with `group by`, then filter groups with `having`.
5. Project with `select`, applying `distinct`.
6. Sort with `order by`.
7. Cut with `limit` and `offset`.

Sources come in three shapes. A plain table serves as an array of records through the built-in in-memory provider. A value whose metatable carries `__query` supplies its own row iterator. Native sources such as [`io.sqlite`](/manual/api#io.sqlite) table references push accepted conjuncts down as parameterized SQL. All providers share the same semantics, so the same query text returns the same rows wherever it runs.

The following example filters an in-memory table and projects one field, then runs the same query value again after its source changed.

```lus
local people = {
    { name = "Alice", age = 30 },
    { name = "Bob", age = 17 },
}
local adults = @people as p where p.age >= 18 select p.name

for row in query(adults) do  --> Alice
    print(row.name)
end

people[3] = { name = "Carol", age = 45 }
local names = {}

for row in query(adults) do
    names[#names + 1] = row.name
end

print(table.concat(names, " "))  --> Alice Carol
```

[Queries](/manual/guide#queries) in the guide describes the query language and its clauses.
