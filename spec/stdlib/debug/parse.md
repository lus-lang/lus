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

Parses Lus source code and returns its syntax tree as nested tables followed by `nil`, or `nil` and an error message when the parse fails without recovery.

- `code` is the source, as a string or as a vector of bytes.
- `chunkname` names the chunk in error messages. It defaults to `"=(parse)"`.
- `options` is a table with two boolean fields, `comments` and `recover`, which are both true when absent.

With `comments`, the root lists every comment in a `comments` array. Each comment is a table with `text`, `islong`, `line`, `column`, `endline`, and `endcolumn`. With `recover`, a token that cannot start a statement becomes an `error_stat` node and parsing resumes at the next statement. A parse that stops at an error still returns the tree read so far, and every error is listed in the `errors` array of the root as a table with `line`, `column`, and `message`.

On success the function returns the root node and `nil`. With `recover` set to `false`, a source that does not parse returns `nil` and the error message. With `recover` left on, the function returns a tree whenever it returns, and a program checks `tree.errors` to learn whether the source parsed cleanly. A `code` that is neither a string, a number, nor a vector raises `bad argument #1 to 'parse'`.

Each node is a table with at least `type`, the kind of node such as `"chunk"`, `"local"`, or `"binop"`, and `line` and `column`, the position where it starts. Both positions count from 1, and a column counts bytes. The other fields depend on the type, and `children` holds the statements of a block.

The following example reads the first statement of a chunk, then parses a source with an error in both modes.

```lus
local tree = debug.parse("local x = 1 + 2")
local stat = tree.children[1]
print(tree.type, stat.type, stat.values[1].op)  --> chunk  local  +
local partial = debug.parse("local a = 1\n) 2\n")
print(#partial.errors, partial.errors[1].line)  --> 1  2
print(debug.parse("local = 1", "input.lus", { recover = false }))
--> nil  [string "input.lus"]:1: <name> expected near '='
```

A list field such as `children` is absent when the list is empty, so a walk over the tree reads `node.children or {}`. The `lus ast` command prints the same tree as JSON, and `spec/language/ast.schema.json` describes its shape. The [syntax trees](/manual/tools#syntax-trees) section of the developer tools page lists every node type, and [`debug.format`](/manual/api#debug.format) formats source with the same parser.
