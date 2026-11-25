---
name: crypto.ulid
module: crypto
kind: function
since: 2.0.0
stability: unstable
origin: lus
returns: string
---

Returns a new ULID, a sortable identifier of 128 bits written as 26 characters.

A ULID holds the Unix time in milliseconds in its first 48 bits and 80 bits from the secure random source after them. The text form is Crockford's base32 in uppercase, which leaves out the letters I, L, O, and U, so ULIDs sort as strings in the order of their times. Within one Lus state, each ULID is greater than the one before it. When two fall in the same millisecond, the second is the first plus one, as the ULID specification defines it. Each worker has a sequence of its own.

The following example makes two ULIDs and checks their length and order.

```lus
local a, b = crypto.ulid(), crypto.ulid()
print(#a, a < b)  --> 26  true
print(a:find("^[0-9A-HJKMNP-TV-Z]+$") ~= nil)  --> true
```

[`crypto.uuid`](/manual/api#crypto.uuid) returns UUIDs, the identifier format that most databases store natively.
