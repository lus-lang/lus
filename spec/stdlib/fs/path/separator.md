---
name: fs.path.separator
module: fs.path
kind: constant
since: 0.1.0
stability: stable
origin: lus
type: string
---

The character that separates the components of a path, `"/"` on POSIX systems and `"\"` on Windows.

The value is a one-character string fixed when the runtime is built, and reading it needs no permission. [`fs.path.join`](/manual/api#fs.path.join) places it between components.

```lus
print(fs.path.separator)               --> /
print(fs.path.join("a", "b") == "a" .. fs.path.separator .. "b")   --> true
```

The example prints the output shown on POSIX systems. [`fs.path.delimiter`](/manual/api#fs.path.delimiter) separates the entries of a path list.
