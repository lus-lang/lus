---
name: warn
module: base
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: msg1
    type: string
vararg: true
---

`warn(msg1, ...)` concatenates its arguments into one message and emits it as a warning, and returns no values.

Each argument must be a string or a number, and any other value raises `bad argument #N to 'warn' (string expected, got TYPE)`. A call with no arguments raises `bad argument #1 to 'warn' (string expected, got no value)`.

Warnings are off when `lus` starts, and the `-W` option turns them on. While they are on, `lus` writes each message to standard error as `Lus warning: MESSAGE`. A single argument that starts with `@` is a control message and is never written. `"@on"` turns warnings on, `"@off"` turns them off, and any other control message is ignored.

```lus
warn("@on")
warn("cache size ", 512, " exceeds the limit")
--> Lus warning: cache size 512 exceeds the limit
warn("@off")
warn("this warning is dropped")
```

An error raised in a `__gc` finalizer is written as a warning of the form `Lus warning: MESSAGE (error in __gc)`, even while warnings are off.
