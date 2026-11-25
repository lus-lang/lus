---
name: os.pid
module: os
kind: function
since: 2.0.0
stability: stable
origin: lus
returns: integer
---

Returns the id that the operating system gave the running process, as an integer.

The function takes no arguments and requires no permission. The id stays the same for the life of the process. Every worker of the process returns the same id. A child process that [`os.spawn`](/manual/api#os.spawn) or [`io.popen`](/manual/api#io.popen) starts sees it as the id of its parent. The WebAssembly build has no processes, so there the call raises `os.pid is unavailable in the WebAssembly build`.

The following example names a scratch file after the process, so two copies of a script that run at the same time write different files.

```lus
local name = `report-$(os.pid()).tmp`
print(name:match("^report%-%d+%.tmp$") == name)   --> true
```

[`os.getenv`](/manual/api#os.getenv) reads the environment of the process. [`os.exit`](/manual/api#os.exit) ends the process.
