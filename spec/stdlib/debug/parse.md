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

Parses a Lus source string and returns its AST (Abstract Syntax Tree) as a nested table structure, followed by `nil`. When the source cannot be parsed, it returns `nil` and the error message.

The optional `chunkname` argument specifies the name used in error messages (defaults to `"=(parse)"`). The code may also be given as a vector of bytes.

```lus
local ast = debug.parse("local x = 1 + 2")
-- Returns: {type = "chunk", line = 1, children = {...}}
```

Each AST node is a table with at minimum `type` (node type string), `line`, and `column` (source position). The root carries a `comments` array when the source has comments.

The optional `options` table takes two boolean fields, both true by default. With `comments`, the root lists every comment. With `recover`, a token that cannot start a statement becomes an `error_stat` node and parsing resumes at the next statement, and a parse that stops at an error still returns the tree read so far. Every error is then listed in the `errors` array of the root. `lus ast` prints the same tree as JSON, and `spec/language/ast.schema.json` describes its shape.
