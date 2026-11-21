---
name: fs.path.join
module: fs.path
kind: function
since: 0.1.0
stability: stable
origin: lus
vararg: true
returns: string
---

Joins its arguments into one path with the platform separator and returns the path as a string.

Every argument is a path component given as a string, and a number is converted to a string. Empty arguments are skipped, and no separator is added where one is already present. An absolute argument replaces everything before it. With no arguments, the result is the empty string. A `nil` or other non-string argument raises a `bad argument` error. The function never touches the filesystem and needs no permission.

The following example shows a plain join, an absolute component, and a component that already ends in a separator.

```lus
print(fs.path.join("dir", "sub", "file.txt"))   --> dir/sub/file.txt
print(fs.path.join("relative", "/absolute"))    --> /absolute
print(fs.path.join("a/", "", "b"))              --> a/b
```

The example prints the output shown on POSIX systems, where the separator is `/`. [`fs.path.split`](/manual/api#fs.path.split) takes a path apart into its components.
