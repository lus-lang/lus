---
name: package.loaded
module: package
kind: variable
since: 0.1.0
stability: stable
origin: lua
type: table
---

`package.loaded` is the table in which `require` caches every loaded module, keyed by module name.

When `require(name)` finds a truthy value at `package.loaded[name]`, it returns that value without searching. After it loads a module, it stores the result of the loader there, or `true` when the loader returned `nil`. The table starts with the standard libraries, such as `string`, `table`, `math`, `io`, `fs`, and `network`, and with `_G` for the global table.

```lus
print(package.loaded.string == string)   --> true
package.loaded.config = { debug = true }
print(require("config").debug)           --> true
package.loaded.config = nil
```

Assigning `nil` to an entry makes the next `require` of that name load the module again. `require` keeps the table that the package library created, so assigning a new table to `package.loaded` leaves the cache in place. [`require`](/manual/api#require) describes the whole loading process.
