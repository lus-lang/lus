---
name: debug.check
module: debug
kind: function
since: 2.0.0
stability: stable
origin: lus
params:
  - name: source
    type: string
  - name: chunkname
    type: string
    optional: true
returns: table
---

Checks Lus source code as `lus check` does and returns its diagnostics as a list, without running the code.

- `source` is the code to check.
- `chunkname` names the chunk. It defaults to `"=check"`. A name that ends in `_test.lus` checks the code as a test file, whose names `skip`, `raises`, `same`, `snapshot`, and `TEST_DIR` count as defined.

The result is a list of tables in source order, one per diagnostic, with these fields:

- `line`, `column`, `endline`, and `endcolumn`: the position of the diagnostic. Lines and columns start at 1, and columns count characters.
- `severity`: `"error"`, `"warning"`, or `"hint"`.
- `code`: the stable code of the diagnostic, such as `"unused-local"` or `"concat-in-loop"`. `lus check --list` lists every code.
- `message`: the text that `lus check` prints.
- `fix`: present when a rewrite resolves the diagnostic without changing what the program does, as `lus check --fix` applies it. It is a list of edits that apply together, each with `line`, `column`, `endline`, and `endcolumn`, positioned like the diagnostic, and the replacement `text`. An edit whose start and end are equal inserts its text.

A source that does not parse yields one diagnostic with the code `"syntax"`. The globals of the running state count as defined. The check never runs `<meta>` initializers or any other code of the source.

A `source` that is not a string raises `bad argument #1 to 'check'`.

The following example finds a string that grows by concatenation in a loop.

```lus
local code = 'local s = ""\nfor i = 1, 3 do s = s .. i end\nprint(s)'
for _, d in ipairs(debug.check(code)) do
    print(d.line, d.severity, d.code)
end
--> 2  hint  concat-in-loop
```

The language server shows the hints of `debug.check` in the editor and offers their fixes as quick fixes. A comment `-- lus: allow(CODE)` in the source suppresses a warning or a hint here as it does in `lus check`. [`debug.parse`](/manual/api#debug.parse) returns the syntax tree of the same source.
