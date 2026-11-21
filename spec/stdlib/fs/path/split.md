---
name: fs.path.split
module: fs.path
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
returns: table
---

Splits `path` at its separators and returns an array of the components.

`path` is a string. An absolute path starts with an empty component, a trailing separator adds none, and two separators in a row give an empty component between them. The empty path gives an empty array, and `"/"` gives an array that holds one empty string. The function never touches the filesystem and needs no permission.

```lus
local parts = fs.path.split("/usr/local/bin")
print(#parts, parts[1] == "", parts[2], parts[4])   --> 4  true  usr  bin
print(#fs.path.split("a/b/"))                       --> 2
```

[`fs.path.join`](/manual/api#fs.path.join) puts components back together.
