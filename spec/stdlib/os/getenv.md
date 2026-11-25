---
name: os.getenv
module: os
kind: function
since: 0.1.0
stability: stable
pledges: ["env:read"]
origin: lua
params:
  - name: varname
    type: string
returns: string|nil
---

Returns the value of the environment variable `varname` as a string, or `nil` when the variable is not set.

`varname` is a string, and a missing argument raises a `bad argument` error. The call requires the `env:read` permission for `varname`, which `env` includes, and without it raises `permission "env:read" denied for 'VARNAME'`. The permission can be limited to individual variables, as in `pledge("env:read=HOME")`, and a request for any other variable then raises the same error, whether or not that variable is set.

```lus
pledge("env")
print(type(os.getenv("PATH")))  --> string
print(os.getenv("LUS_EXAMPLE_UNSET_VARIABLE"))  --> nil
```

A variable that is set to the empty string returns the empty string. A variable that [`os.setenv`](/manual/api#os.setenv) changed returns its new value. [Permissions](/manual/permissions) describes values that limit a permission.
