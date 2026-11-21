---
name: range
module: base
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: start
    type: number
  - name: limit
    type: number
    optional: true
  - name: step
    type: number
    optional: true
returns: function
---

`range(start, limit, step)` returns an iterator function that produces the numbers from `start` to `limit` inclusive, advancing by `step`.

The parameters describe the sequence:

- `start` is the first number. With a single argument, `range(n)` counts from 1 to `n`.
- `limit` is the last number the sequence may reach.
- `step` is the difference between consecutive numbers and defaults to `1`. A negative `step` counts down.

`range` returns one function. Each call of the function returns the next number, and `nil` once the number passes `limit`, so a sequence whose `start` already lies past `limit` is empty. Over integers and floats the sequence follows the rules of the numeric `for`. An integer `start` and `step` give integers, and a float `start` or `step` makes every number a float. Bigints and decimals step with exact arithmetic, and a numeric string converts to a number. A `step` of zero raises `bad argument #3 to 'range' (step must not be zero)`, and an argument that is not a number raises `number expected`.

```lus
for i in range(1, 5) do io.write(i, " ") end print()        --> 1 2 3 4 5
for i in range(10, 1, -3) do io.write(i, " ") end print()   --> 10 7 4 1
for i in range(3) do io.write(i, " ") end print()           --> 1 2 3

local next_even = range(2, 4, 2)
print(next_even(), next_even(), next_even())                 --> 2  4  nil
```

The iterator keeps its position in its own upvalues, so it works in a generic `for`, when stored and called directly, and when passed to other functions. `range(1, 2, 0.5)` produces `1.0`, `1.5`, and `2.0`, and `range(math.maxinteger - 1, math.maxinteger)` produces two integers and ends. A `for` loop that calls the builtin `range` directly with integer or float arguments runs the numeric loop, `for i = start, limit, step`, without the function or its calls, as [Numeric for](/manual/guide#numeric-for) describes.
