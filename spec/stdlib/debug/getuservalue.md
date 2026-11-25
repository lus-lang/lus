---
name: debug.getuservalue
module: debug
kind: function
since: 0.1.0
pledges: ["debug"]
stability: stable
origin: lua
params:
  - name: u
    type: userdata
  - name: n
    type: integer
    optional: true
returns: any
---

Returns the user value at an index of a full userdata and `true`, or `nil` when the value has no such user value.

- `u` is the value to inspect. It may be of any type.
- `n` is the index of the user value, starting at 1. It defaults to 1.

A _user value_ is a Lus value stored inside a full userdata, next to its memory block. A userdata has a fixed number of user value slots, set when it is created. In the standard library, a named zone keeps its IANA name in its first slot, and a zoned value keeps its zone there. If `u` is a full userdata with a slot at index `n`, the function returns the value in that slot and `true`. Otherwise it returns a single `nil`, which covers every value that is not a userdata and every index outside the slots. A non-integer `n` raises `bad argument #2 to 'getuservalue'`.

The following example reads the user value of a zone and of a zoned value.

```lus
local paris = time.zone("Europe/Paris")
print(debug.getuservalue(paris))                 --> Europe/Paris  true
local z = time.zoned({ year = 2026 }, paris)
print(debug.getuservalue(z) == paris)            --> true
print(debug.getuservalue(paris, 2))              --> nil
print(debug.getuservalue({}))                    --> nil
```

A slot that holds `nil` returns `nil` and `true`, which tells it apart from a missing slot. [`debug.setuservalue`](/manual/api#debug.setuservalue) stores a value in a slot.
