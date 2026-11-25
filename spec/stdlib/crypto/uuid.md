---
name: crypto.uuid
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: version
    type: integer
    optional: true
returns: string
---

Returns a new UUID as defined by RFC 9562, as a string of 36 characters in the canonical lowercase form.

- `version` is `4`, the default, or `7`.

A version 4 UUID holds 122 bits from the secure random source, so it is unguessable. A version 7 UUID starts with the Unix time in milliseconds, then holds 74 more bits. Version 7 UUIDs sort by the time they were made, which keeps the index of a database table ordered as rows arrive. Within one Lus state, each version 7 UUID is greater than the one before it. When two fall in the same millisecond, the second is the first plus one, which is the monotonic method of RFC 9562, so the bits after the time are unguessable only for the first UUID of each millisecond. Each worker has a sequence of its own.

A `version` other than 4 or 7 raises `bad argument #1 to 'uuid' (version 4 or 7 expected)`.

The following example checks the version digit of each kind and the order of two version 7 UUIDs.

```lus
local id = crypto.uuid()
print(#id, id:sub(15, 15))  --> 36  4
local a, b = crypto.uuid(7), crypto.uuid(7)
print(a:sub(15, 15), a < b)  --> 7  true
```

[`crypto.ulid`](/manual/api#crypto.ulid) returns a sortable identifier in a shorter text form.
