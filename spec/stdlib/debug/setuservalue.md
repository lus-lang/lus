---
name: debug.setuservalue
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: u
    type: userdata
  - name: value
    type: any
  - name: n
    type: integer
    optional: true
returns: userdata|nil
---

Stores a value in a user value slot of a full userdata and returns the userdata, or returns `nil` when the slot does not exist.

- `u` is a full userdata.
- `value` is the value to store, of any type, including `nil`.
- `n` is the index of the slot, starting at 1. It defaults to 1.

If `u` has a slot at index `n`, the function stores `value` there and returns `u`. Otherwise it changes nothing and returns `nil`. A `u` that is not a full userdata raises `bad argument #1 to 'setuservalue' (userdata expected)`. A missing `value` raises `bad argument #2 to 'setuservalue' (value expected)`, so storing `nil` takes an explicit `nil`.

The objects that the runtime makes, such as files, sockets, databases, and zoned times, keep in their slots what they depend on. A `u` of the runtime raises `bad argument #1 to 'setuservalue' (an object of the runtime keeps its user values)`, so the function stores into the userdata of a host program only.

The following example shows the error for a file handle.

```lus
print((catch debug.setuservalue(io.stdout, "tag")))  --> false
```

[`debug.getuservalue`](/manual/api#debug.getuservalue) reads a slot.
