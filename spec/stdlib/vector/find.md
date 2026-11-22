---
name: vector.find
module: vector
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: v
    type: vector
  - name: pattern
    type: string|vector
  - name: init
    type: integer
    optional: true
returns: integer|nil
---

Returns the zero-based offset of the first occurrence of the bytes of `pattern` in a vector at or after `init`, or `nil` when there is none.

- `v` is the vector to search.
- `pattern` is the byte sequence to find, a vector or a string. A string contributes its WTF-8 bytes.
- `init` is the zero-based offset where the search starts. It defaults to 0.

The search is plain, so every byte of `pattern` matches only itself, unlike the patterns of [`string.find`](/manual/api#string.find). An empty `pattern` matches at `init`. An `init` below 0 or past the size of the vector returns `nil`. A `v` that is not a vector raises `bad argument #1 to 'find' (vector expected)`. A `pattern` that is neither a string, a number, nor a vector raises `bad argument #2 to 'find' (string or vector expected, got table)` with its type.

The following example splits a multipart body at its boundary.

```lus
local body = vector.fromstring("--x\r\nfirst\r\n--x\r\nsecond\r\n--x--")
local parts = {}
local at = vector.find(body, "--x")
while true do
    local start = at + 5
    local next_at = vector.find(body, "\r\n--x", start)
    if not next_at then break end
    parts[#parts + 1] = vector.tostring(body, start, next_at)
    at = next_at + 2
end
print(parts[1], parts[2])   --> first  second
```
