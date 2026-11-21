---
name: utf8.codes
module: utf8
kind: function
since: 0.1.0
stability: stable
origin: lua
params:
  - name: s
    type: string
  - name: lax
    type: boolean
    optional: true
returns: function
---

`utf8.codes(s, lax)` returns an iterator function, `s`, and `0`, so that `for pos, cp in utf8.codes(s)` visits each character of `s` with its position and code point.

The parameter `s` is the string to traverse. Positions count characters, like every string position, so they run from 1 to `#s`. The optional `lax`, when truthy, accepts lone surrogates. Without it, the loop raises `invalid UTF-8 code` when it reaches a lone surrogate, after it has visited the characters before it.

```lus
for pos, cp in utf8.codes("hé😀") do
    print(pos, cp)
end
--> 1  104
--> 2  233
--> 3  128512
```

[`utf8.codepoint`](/manual/api#utf8.codepoint) returns the code points of a range at once.
