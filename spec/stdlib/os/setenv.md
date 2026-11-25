---
name: os.setenv
module: os
kind: function
since: 2.0.0
stability: stable
pledges: ["env:write"]
origin: lus
params:
  - name: varname
    type: string
  - name: value
    type: string|nil
    optional: true
returns: nil
---

Sets the environment variable `varname` to `value`, or removes the variable when `value` is `nil`.

`varname` is a string that is not empty and contains neither `=` nor a zero byte. `value` is a string without a zero byte, or `nil`. Any other name raises `bad argument #1 to 'setenv' (invalid environment variable name)`, and a value with a zero byte raises `bad argument #2 to 'setenv' (environment variable value contains a zero byte)`. Removing a variable that is not set does nothing. The call returns no values.

The call requires the `env:write` permission for `varname`, which `env` includes, and without it raises `permission "env:write" denied for 'VARNAME'`. The permission can be limited to individual variables or to a pattern, as in `pledge("env:write=APP_*")`.

```lus
pledge("env")
os.setenv("LUS_EXAMPLE_MODE", "fast")
print(os.getenv("LUS_EXAMPLE_MODE"))  --> fast
os.setenv("LUS_EXAMPLE_MODE", nil)
print(os.getenv("LUS_EXAMPLE_MODE"))  --> nil
```

The change applies to the state that makes it. [`os.getenv`](/manual/api#os.getenv) reads the new value, and a child process that [`os.execute`](/manual/api#os.execute) or [`io.popen`](/manual/api#io.popen) starts afterwards receives the changed environment. A worker receives a copy of the environment of its creator when it starts, so later changes on either side stay on that side.
