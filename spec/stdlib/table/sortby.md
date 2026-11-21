---
name: table.sortby
module: table
kind: function
since: 1.6.0
stability: stable
origin: lus
params:
  - name: array
    type: table
  - name: keyfunc
    type: function
  - name: asc
    type: boolean
    optional: true
---

Sorts the list `array` in place by the key that `keyfunc(element)` returns for each element.

`array` is the list to sort, from index 1 to `#array`. `keyfunc` is called exactly once for each element, with the element as its only argument, and its result is the sort key. `asc` defaults to true, which sorts in ascending order of the keys. A falsy `asc` sorts in descending order.

The function returns no values. The sort is stable, so elements with equal keys keep their relative order in both directions.

Keys that `<` cannot compare raise the comparison error, such as `attempt to compare string with number`. An `array` that is not a table, or a `keyfunc` that is not a function, raises a type error. An error raised by `keyfunc` propagates.

```lus
local people = {{name = "a", age = 30}, {name = "b", age = 20}, {name = "c", age = 30}}
table.sortby(people, function(p) return p.age end)
print(people[1].name, people[2].name, people[3].name)   --> b  a  c
table.sortby(people, function(p) return p.age end, false)
print(people[1].name, people[2].name, people[3].name)   --> a  c  b
```

An expensive key function therefore runs `#array` times, once for each element. [`table.sort`](/manual/api#table.sort) takes a comparator, and [`table.groupby`](/manual/api#table.groupby) collects the elements that share a key.
