---
name: ipairs
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

`ipairs(t)` returns an iterator function, `t`, and `0`, so that `for i, v in ipairs(t)` visits `t[1]`, `t[2]`, and so on up to the first index whose value is `nil`.

The parameter `t` is the value to traverse, usually a table. Each step reads `t[i]` through the `__index` metamethod when `t` has one, so `ipairs` also traverses proxies. The loop yields the index and the value at each step and stops at the first `nil` value, so the elements after a hole are not visited.

A call with no arguments raises `bad argument #1 to 'ipairs' (value expected)`. A value that cannot be indexed raises its indexing error at the first step of the loop.

```lus
for i, v in ipairs({ "a", "b", nil, "d" }) do
    print(i, v)
end
--> 1  a
--> 2  b
```

[`pairs`](/manual/api#pairs) visits every key of a table, and [`range`](/manual/api#range) counts over numbers.
