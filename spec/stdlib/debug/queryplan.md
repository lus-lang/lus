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

Describes how a query would run, as a string, without running it.

- `q` is a query value, built with the `@` syntax.

The function returns a string of several lines that ends with a newline. The first line gives the number of sources and of `where` conjuncts, where a _conjunct_ is one operand of a top-level `and` in the `where` clause. A line per source follows, naming its alias, its provider, and the number of conjuncts pushed down to it. The provider is `memory` for a plain table, `__query` for a value with a `__query` metamethod, and `native` for a backend such as an SQLite table. A line per conjunct then gives where it runs: `pushed down`, `in memory (host closure)` for a conjunct that calls a Lus function, or `in memory (translatable)` for one the provider declined.

An argument that is not a query raises `bad argument #1 to 'queryplan' (query expected)`.

The following example plans a query over an SQLite table. The first conjunct becomes part of the SQL statement, the second calls a Lus function, and the third uses division, which the SQLite provider leaves in memory.

```lus
local db = io.sqlite(":memory:")
db:exec("CREATE TABLE users (name TEXT, age INTEGER)")
local function adult(age) return age >= 18 end
local q = @db.users as u where u.age >= 18 and adult(u.age) and u.age / 2 > 3 select u.name
io.write(debug.queryplan(q))
--> query: 1 source(s), 3 conjunct(s)
-->   u: native, 1 pushed conjunct(s)
-->   conjunct 1: pushed down
-->   conjunct 2: in memory (host closure)
-->   conjunct 3: in memory (translatable)
```

The plan gives tests a direct observation of push-down decisions, which change how a query runs but never which rows it returns. The [queries](/manual/guide#queries) section of the guide describes providers and push-down, and [`query`](/manual/api#query) runs a query.
