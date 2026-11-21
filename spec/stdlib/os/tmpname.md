---
name: os.tmpname
module: os
kind: function
since: 0.1.0
stability: stable
pledges: ["fs:write"]
origin: lua
returns: string
---

Creates an empty file with a fresh name in the temporary directory and returns its path.

The function takes no arguments. On POSIX systems the file is `/tmp/lua_` followed by six random letters and digits, and on Windows it lies in the directory named by `TEMP`, or in the working directory when `TEMP` is unset. The file is created exclusively, so no other program holds the same name, and it stays on disk until the program removes it.

On success the call returns one string. When 100 attempts find no free name, or the directory cannot be written, the call raises `"unable to generate a unique filename"`. The call requires `fs:write`. Any grant of `fs:write` permits it, including one limited to other paths, while writing and removing the file afterwards are checked against the path as usual.

```lus
pledge("fs")
local path = os.tmpname()
io.open(path, "w"):write("draft"):close()
print(io.open(path):read("a"))   --> draft
fs.remove(path)
```

[`io.tmpfile`](/manual/api#io.tmpfile) opens a temporary file that has no name and removes itself.
