---
name: next
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: t
    type: table
  - name: k
    type: any
    optional: true
returns: any
---

`next(t, k)` returns the key that follows `k` in the table `t` and the value stored at it, or `nil` when `k` is the last key.

The parameter `t` is the table to traverse. The optional `k` is a key of `t`. When `k` is `nil` or absent, `next` returns the first key and its value.

`next` reads the table directly and ignores metamethods. An empty table returns `nil`, so `next(t) == nil` tests whether a table is empty. A `k` that is not a key of `t` raises `invalid key to 'next'`, and a `t` that is not a table raises `bad argument #1 to 'next' (table expected, got TYPE)`.

```lus
print(next({}))                   --> nil
print(next({ "only" }))           --> 1  only
print(next({ "only" }, 1))        --> nil
```

The order of traversal is unspecified, even for integer keys. During a traversal a program may assign `nil` to existing fields, and assigning to a key that is absent makes the rest of the traversal unspecified. [`pairs`](/manual/api#pairs) wraps `next` for use in a generic `for`.
