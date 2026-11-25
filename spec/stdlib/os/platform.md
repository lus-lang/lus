---
name: os.platform
module: os
kind: function
since: 0.1.0
stability: stable
origin: lus
returns: string
---

Returns a lowercase string that names the operating system the runtime was built for.

The function takes no arguments and requires no permission. The names are `uname -s` style identifiers: `"linux"`, `"darwin"` for every Apple platform, `"freebsd"`, `"netbsd"`, `"openbsd"`, `"sunos"` for illumos, `"windows"`, and `"wasi"` for the WebAssembly build. DragonFly BSD and Haiku report `"posix"`, and any other system reports `"unknown"`.

```lus
local name = os.platform()
local separator = name == "windows" and "\\" or "/"
print(separator == fs.path.separator)  --> true
```

[`fs.path.separator`](/manual/api#fs.path.separator) and [`fs.path.delimiter`](/manual/api#fs.path.delimiter) hold the path characters of the platform.
