---
name: worker.peek
module: worker
kind: function
since: 0.1.0
stability: stable
origin: lus
returns: any
---

*(Worker-side only)* Blocking receive from the worker's inbox. Blocks until a message from the parent (via `worker.send()`) is available.
