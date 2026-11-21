---
name: vector.unpackmany
module: vector
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: v
    type: vector
  - name: offset
    type: integer
  - name: fmt
    type: string
  - name: count
    type: integer
    optional: true
returns: function
---

Returns an iterator that reads values from a vector in the layout of a format string, again and again, starting at an offset.

- `v` is the vector to read.
- `offset` is the zero-based position of the first record.
- `fmt` is a format string, with the options of [`string.unpack`](/manual/api#string.unpack). Each call of the iterator reads one record in this format.
- `count` is the largest number of records to read, an integer of 0 or more. It defaults to 0, which places no limit.

Each call of the iterator returns the values of one record and moves past it. The loop ends when the next offset reaches the end of the vector, or after `count` records. A record that would run past the end raises `unpack falls out of bounds` from the iterator, so a trailing partial record is an error. An offset below 0 or after the end raises `bad argument #2 to 'unpackmany' (offset out of bounds)`, and a negative `count` raises `bad argument #4 to 'unpackmany' (count must be non-negative)`.

The following example reads pairs of 16-bit integers, then the first two values with a count.

```lus
local v = vector.create(8)
vector.pack(v, 0, "<I2I2I2I2", 1, 2, 3, 4)
for a, b in vector.unpackmany(v, 0, "<I2I2") do
    print(a, b)
end
--> 1  2
--> 3  4
for n in vector.unpackmany(v, 0, "<I2", 2) do io.write(n, " ") end
print()                                      --> 1 2
```

The iterator reads the vector as it is at each call, so a change to the vector during the loop affects later records. [`vector.unpack`](/manual/api#vector.unpack) reads one record and also returns the next offset.
