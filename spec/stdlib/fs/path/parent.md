---
name: fs.path.parent
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

Returns the parent of `path`, which is the part before its last separator, or `"."` when `path` has no separator.

`path` is a string, and a missing or `nil` argument raises a `bad argument` error. The result is always a string. The parent of a path without a separator, including the empty path, is `"."`. The parent of an entry directly under the root, and of the root itself, is the root. A path that ends in a separator has the part before that separator as its parent, so the parent of `"a/b/"` is `"a/b"`. Only the last separator is removed, so the parent of `"a//b"` is `"a/"`. The function never touches the filesystem and needs no permission.

```lus
print(fs.path.parent("/home/user/report.pdf"))  --> /home/user
print(fs.path.parent("/etc"))  --> /
print(fs.path.parent("report.pdf"))  --> .
```

The example prints the output shown on POSIX systems. [`fs.path.name`](/manual/api#fs.path.name) returns the part after the last separator.
