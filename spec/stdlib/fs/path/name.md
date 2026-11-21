---
name: fs.path.name
module: fs.path
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: path
    type: string
returns: string
---

Returns the final component of `path`, which is the part after its last separator.

`path` is a string, and a missing or `nil` argument raises a `bad argument` error. A path without a separator is returned whole. A path that ends in a separator, such as `"/"` or `"dir/"`, has the empty string as its name, and so does the empty path. The function never touches the filesystem and needs no permission.

```lus
print(fs.path.name("/home/user/report.pdf"))   --> report.pdf
print(fs.path.name("report.pdf"))              --> report.pdf
print(fs.path.name("dir/") == "")              --> true
```

[`fs.path.parent`](/manual/api#fs.path.parent) returns the part before the last separator.
