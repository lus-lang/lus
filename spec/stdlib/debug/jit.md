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

Reports on the JIT. Called with no argument, it returns four values. The first is the setting of the baseline tier as a string: `"on"` when hot functions compile to native code, `"eager"` when every function compiles on its first call, and `"off"` when the state only interprets. The setting is `"off"` in a build without a JIT, on a platform without one, and under `LUS_JIT=off`. The second is the setting of the optimizing tier, with the same three strings. The third and fourth are counters of the optimizing tier: the pieces of optimized code it compiled, and the times optimized code left through a failed guard.

Called with a function, it returns two booleans: whether that function has native code now, and whether it has optimized code in use. A native function has neither.

The JIT changes how fast a program runs and nothing else, so this function exists for tests and for measurements.
