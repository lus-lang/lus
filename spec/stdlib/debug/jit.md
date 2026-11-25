---
name: debug.jit
module: debug
kind: function
since: 2.0.0
stability: unstable
origin: lus
params:
  - name: f
    type: function
    optional: true
returns: string | boolean
---

Reports the settings and counters of the JIT, or whether a given function has native code and optimized code.

- `f` is an optional function. Without it, the function reports on the state. With it, the function reports on `f`.

Called with no argument, the function returns four values:

1. The setting of the baseline tier as a string. It is `"on"` when hot functions compile to native code, `"eager"` when every function compiles on its first call, and `"off"` when the state only interprets.
2. The setting of the optimizing tier, with the same three strings.
3. The number of pieces of optimized code that the optimizing tier has compiled, an integer.
4. The number of times optimized code has left through a failed guard, an integer.

The settings follow the environment variable `LUS_JIT`. The default and `LUS_JIT=on` report `"on"` and `"on"`. `LUS_JIT=baseline` reports `"on"` and `"off"`, `LUS_JIT=eager` reports `"eager"` and `"off"`, `LUS_JIT=opt-eager` reports `"eager"` and `"eager"`, and `LUS_JIT=off` reports `"off"` and `"off"`. A build without a JIT, and a platform without one, report `"off"` for both tiers.

Called with a function, it returns two booleans: whether `f` has native code now, and whether it has optimized code in use. A native function returns `false` and `false`. An `f` that is not a function raises `bad argument #1 to 'jit' (function expected)`.

The following example reads the report of the state and of two functions. The values themselves depend on the setting and on how often a function has run, so the example prints only their types and the result for a native function.

```lus
local base, opt, units, exits = debug.jit()
print(type(base), type(opt), math.type(units), math.type(exits))

--> string  string  integer  integer
local function add(a, b)
    return a + b
end

local native, optimized = debug.jit(add)
print(type(native), type(optimized))  --> boolean  boolean
print(debug.jit(print))  --> false  false
```

The JIT changes how fast a program runs and nothing else, so this function serves tests and measurements. A function compiles once it is hot, so `debug.jit(f)` may return `false` before a loop and `true` after it under the default setting.
