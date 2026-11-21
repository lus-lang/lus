---
name: "file:isatty"
module: io
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: file
returns: boolean
---

Returns `true` when the file handle is a terminal, and `false` otherwise.

The standard streams are terminals when the program runs in an interactive terminal and are not redirected. A file opened with [`io.open`](/manual/api#io.open), a pipe, and a redirected stream return `false`. A program uses the result to decide whether to print colors or to ask questions interactively. The method needs no permission, and a closed handle raises `attempt to use a closed file`.

```lus
local color = io.stdout:isatty()
print(type(color))   --> boolean
```

[`file:setraw`](/manual/api#file:setraw) switches a terminal to raw input.
