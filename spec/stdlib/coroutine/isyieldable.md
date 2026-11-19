---
name: coroutine.isyieldable
module: coroutine
kind: function
since: 0.1.0
stability: stable
origin: lua
returns: boolean
---

Returns `true` if the running coroutine can yield. A coroutine is not yieldable when it is the main thread or inside a non-yieldable C function.
