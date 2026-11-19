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

Reports on the baseline JIT. Called with no argument, it returns the setting of the running state as a string: `"on"` when hot functions compile to native code, `"eager"` when every function compiles on its first call, and `"off"` when the state only interprets. The setting is `"off"` in a build without a JIT, on a platform without one, and under `LUS_JIT=off`.

Called with a function, it returns `true` when that function has native code now and `false` otherwise. A native function never has any.

The JIT changes how fast a program runs and nothing else, so this function exists for tests and for measurements.
