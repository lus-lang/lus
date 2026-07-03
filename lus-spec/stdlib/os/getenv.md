---
name: os.getenv
module: os
kind: function
since: 0.1.0
stability: stable
pledges: ["env"]
origin: lua
params:
  - name: varname
    type: string
returns: string|nil
---

Returns the value of the environment variable `varname`, or `nil` if the variable is not defined.

The `env` pledge can be scoped to individual variables, e.g. `pledge("env=HOME")`.
