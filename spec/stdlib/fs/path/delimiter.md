---
name: fs.path.delimiter
module: fs.path
kind: constant
since: 0.1.0
stability: stable
origin: lus
type: string
---

The character that separates the entries of a path list such as the `PATH` environment variable, `":"` on POSIX systems and `";"` on Windows.

The value is a one-character string fixed when the runtime is built, and reading it needs no permission.

The following example splits a path list into its entries.

```lus
local list = table.concat({ "/usr/bin", "/bin" }, fs.path.delimiter)

for entry in list:gmatch("[^" .. fs.path.delimiter .. "]+") do
    print(entry)
end
--> /usr/bin
--> /bin
```

The example prints the output shown on POSIX systems. [`fs.path.separator`](/manual/api#fs.path.separator) separates the components of one path.
