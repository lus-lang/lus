---
name: string.format
module: string
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: formatstring
    type: string
vararg: true
returns: string
---

Return a formatted string following the description in `formatstring`, which follows `printf`-style directives. Accepts `%d`, `%i`, `%u`, `%f`, `%e`, `%g`, `%x`, `%o`, `%s`, `%q`, `%c`, and `%%`.
