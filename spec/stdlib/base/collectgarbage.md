---
name: collectgarbage
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: opt
    type: string
    optional: true
  - name: arg
    type: any
    optional: true
returns: any
---

`collectgarbage(opt, arg)` runs the garbage collector operation that `opt` names and returns its result.

The parameter `opt` is the name of the operation and defaults to `"collect"`. The parameter `arg` is used by `"step"` and `"param"`. The operations and their results are these.

- `"collect"` performs a full collection cycle, runs the pending `__gc` finalizers, and returns `0`.
- `"stop"` stops automatic collection until `"restart"`, and returns `0`. `"restart"` resumes it and returns `0`.
- `"count"` returns the memory in use, in kilobytes, as a float.
- `"step"` performs a collection step and returns `true` when the step finished a cycle and `false` otherwise. A positive `arg` asks for that many kilobytes of collection work, and the default `0` performs one basic step.
- `"isrunning"` returns `true` unless automatic collection was stopped with `"stop"`.
- `"incremental"` and `"generational"` switch the collector to that mode and return the name of the previous mode. The collector starts in generational mode. Entering generational mode runs a full collection.
- `"param"` reads or sets a tuning parameter. `collectgarbage("param", name, value)` sets the parameter `name` to the non-negative integer `value` and returns its previous value. Without `value`, or with a negative one, it returns the current value unchanged.

The parameter names are `"pause"`, `"stepmul"`, `"stepsize"`, `"minormul"`, `"majorminor"`, and `"minormajor"`. The `pause` parameter sets the heap goal as a percentage of the live data, `stepmul` the marking work per allocated byte, and `stepsize` the allocation in bytes between steps. The `minormul` parameter sets the allocation between minor collections as a percentage of the heap after the last major collection, `minormajor` the growth of the old generation that calls for a major collection, and `majorminor` the percentage of the heap a major collection must free to return to minor collections. The defaults are 150, 200, 9600, 20, 50, and 70.

An unknown operation raises `bad argument #1 to 'collectgarbage' (invalid option 'NAME')`, and an unknown parameter name raises the same error for argument 2. Called from inside a `__gc` finalizer, `collectgarbage` does nothing and returns `nil`.

```lus
print(collectgarbage("isrunning"))          --> true
print(collectgarbage("param", "pause"))     --> 150
print(math.type(collectgarbage("count")))   --> float
print(collectgarbage())                     --> 0
```
