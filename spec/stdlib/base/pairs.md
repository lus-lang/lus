---
name: pairs
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
returns: function
---

`pairs(t)` returns three values, `next`, `t`, and `nil`, so that `for k, v in pairs(t)` visits every key and value of the table `t`.

The parameter `t` is the value to traverse. If `t` has a `__pairs` metamethod, `pairs` calls it with `t` and returns its first three results, which lets an object define its own traversal. Otherwise `t` must be a table, and any other value raises `bad argument #1 to 'pairs' (table expected, got TYPE)`.

```lus
local stock = { apples = 3 }

for name, count in pairs(stock) do
    print(name, count)  --> apples  3
end
```

The order of traversal is unspecified, as it is for [`next`](/manual/api#next). A loop may assign `nil` to fields it has already visited. [`ipairs`](/manual/api#ipairs) visits the integer keys in order.
