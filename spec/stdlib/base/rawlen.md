---
name: rawlen
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
fastcall: true
params:
  - name: v
    type: table|string
returns: integer
---

`rawlen(v)` returns the length of the table or string `v` as an integer, without calling the `__len` metamethod.

For a string, the length is the number of characters, as `#` gives. For a table, it is the length of the sequence that `#` gives for a table without `__len`, which is not well defined when the sequence has holes. Any other value raises `bad argument #1 to 'rawlen' (table or string expected, got TYPE)`.

```lus
local t = setmetatable({ 1, 2, 3 }, {
    __len = function()
        return 99
    end,
})

print(#t, rawlen(t))  --> 99  3
print(rawlen("héllo"))  --> 5
```

[`rawget`](/manual/api#rawget), [`rawset`](/manual/api#rawset), and [`rawequal`](/manual/api#rawequal) bypass the other metamethods. [Length operator](/manual/guide#length) in the guide describes the length of a table.
