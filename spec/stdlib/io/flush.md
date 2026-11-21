---
name: io.flush
module: io
kind: function
since: 0.1.0
stability: stable
origin: lua
returns: boolean|nil
---

Writes any buffered output of the default output file and returns `true`.

The function takes no arguments and requires no permission. It flushes the current default output, which [`io.output`](/manual/api#io.output) sets and which starts as `io.stdout`.

```lus
io.write("buffered\n")   --> buffered
print(io.flush())        --> true
```

`file:flush()` flushes one handle. The runtime also flushes its standard output before [`os.execute`](/manual/api#os.execute) runs a command and before [`os.exit`](/manual/api#os.exit) ends the process.
