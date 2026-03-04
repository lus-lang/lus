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

Emits a warning by concatenating all arguments (which must be strings) and sending the result to the warning system. Warnings beginning with `"@"` are control messages: `"@on"` enables and `"@off"` disables warnings.
