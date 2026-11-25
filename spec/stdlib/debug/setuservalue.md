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

The following example stores a value in a slot that exists and in one that does not. A file handle has no slots, and a named zone has one.

```lus
print(debug.setuservalue(io.stdout, "tag"))  --> nil
local paris = time.zone("Europe/Paris")
print(debug.setuservalue(paris, "Paris") == paris)  --> true
print(debug.getuservalue(paris))  --> Paris  true
print(paris:name())  --> Paris
```

The library types read their own slots, so a store changes their behavior. A zoned value keeps its zone in its slot, and replacing it with any value other than a zone breaks every later operation on that zoned value. [`debug.getuservalue`](/manual/api#debug.getuservalue) reads a slot.
