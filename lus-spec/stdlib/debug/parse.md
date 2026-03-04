---
name: debug.parse
module: debug
kind: function
since: 0.1.0
stability: stable
origin: lus
params:
  - name: code
    type: string
  - name: chunkname
    type: string
    optional: true
  - name: options
    type: table
    optional: true
returns: table|nil
---

Parses a Lus source string and returns its AST (Abstract Syntax Tree) as a nested table structure. Returns `nil` if parsing fails.

The optional `chunkname` argument specifies the name used in error messages (defaults to `"=(parse)"`).

```lus
local ast = debug.parse("local x = 1 + 2")
-- Returns: {type = "chunk", line = 1, children = {...}}
```

Each AST node is a table with at minimum `type` (node type string) and `line` (source line number).
