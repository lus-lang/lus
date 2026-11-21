---
name: io.type
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: obj
    type: any
returns: string|nil
---

Tells whether `obj` is a file handle and returns `"file"` for an open handle, `"closed file"` for a closed one, and `nil` for any other value.

`obj` is any value, and it must be present. A call with no argument raises `bad argument #1 to 'type' (value expected)`, while an explicit `nil` returns `nil`. The function requires no permission.

```lus
pledge("fs:write")
local tmp = io.tmpfile()
print(io.type(tmp))     --> file
tmp:close()
print(io.type(tmp))     --> closed file
print(io.type("file"))  --> nil
```

Handles from [`io.open`](/manual/api#io.open), [`io.popen`](/manual/api#io.popen), and [`io.tmpfile`](/manual/api#io.tmpfile), and the standard files, all count as file handles. The base function [`type`](/manual/api#type) returns `"userdata"` for each of them.
