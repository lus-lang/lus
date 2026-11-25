# Lus language grammar and semantics

This document is the reference for the Lus 2.0 surface language. It covers the lexical grammar, the full syntactic grammar in EBNF, operator precedence, and the static and dynamic semantics of every construct. It is written for implementers and tool authors, and `runtime/src/syntax/parser.zig` follows it.

Lus began as a fork of Lua 5.5 RC 2, so its core rules of scoping, functions, and control flow are those of Lua 5.5. Section 4 states those rules briefly, and every other rule is spelled out in full. [Lus for Lua programmers](/manual/lua) lists the differences for a reader who knows Lua.

Two kinds of annotation appear throughout.

- **Source** lines name the files of the 2.0 runtime that implement a rule, as paths relative to `runtime/src/`.
- **Tested** notes name the conformance test under `tests/conformance/` that asserts the behavior. Every message and example quoted in this document was checked against the 2.0 `lus` binary, and the one exception is marked where it appears.

## Contents

1. Lexical grammar
2. Syntactic grammar
3. Operator precedence
4. Scopes, functions, and control flow
5. Expressions, statements, and declarations
6. Compile-time error catalog
7. Edge cases at a glance
8. Source map

## Notation

The EBNF uses the following conventions. `{ x }` means zero or more repetitions of `x`. `[ x ]` means `x` is optional. `( a | b )` groups alternatives. Quoted text such as `'end'` or `'?'` is a literal token. Capitalized names such as `Name`, `Numeral`, and `LiteralString` are token classes from the lexer. Lowercase names are nonterminals. A rule written as `x(limit)` takes a precedence limit parameter, as described in section 3.

Error messages are quoted exactly as the 2.0 implementation produces them. Syntax errors carry a trailing ` near TOKEN` part. Semantic errors carry no `near` part. Section 6 explains the full message format.

---

## 1. Lexical grammar

**Source:** `syntax/lexer.zig`, `syntax/token.zig`.

### 1.1 Source text and line structure

A chunk is a sequence of bytes. Outside string literals and comments, the lexer accepts only ASCII. Identifier characters are letters `A-Z` and `a-z`, digits `0-9`, and the underscore. A byte at or above 0x80 outside a string literal or comment starts no token and raises a lexical error. Comments may contain any bytes. String literals of every kind must decode to well formed WTF-8 (section 1.6).

A line break is any of `\n`, `\r`, `\r\n`, or `\n\r`. Each of these sequences counts as exactly one line and advances the line counter by one. Every token records its byte span in the source, from which the syntax tree export and the diagnostics derive columns.

Whitespace between tokens is space, `\t`, `\v`, `\f`, and line breaks.

When the first byte of a chunk is `#`, the lexer skips the first line, which enables shebang lines. The rule belongs to the lexer, so it applies to every chunk, and `load("#!x\nreturn 1")` returns a function that returns 1.

**Tested** (`lexer_errors_test.lus`): LF, CRLF, and bare CR all advance the line count identically, so an error on the third line is reported at line 3 for every terminator style.

### 1.2 Comments

A comment starts with `--` anywhere outside a string.

- If `--` is immediately followed by a long bracket opener (`[`, zero or more `=`, `[`), the comment is a long comment that ends at the matching closer of the same level. Its content is discarded.
- Otherwise the comment runs to the end of the line. This includes `--[` followed by something other than a valid opener, such as `--[==x`, which is a short comment.

An unterminated long comment raises `unfinished long comment (starting at line N) near <eof>`.

### 1.3 Names and keywords

```ebnf
Name = ( letter | '_' ) { letter | digit | '_' } ;   (* not a reserved word *)
```

The reserved words are exactly the entries of `token.keywords`, in this order:

```
and       break     catch     continue  do        else      elseif
end       enum      false     for       from      function  global
goto      if        in        local     nil       not       or
provide   repeat    return    then      true      until     while
```

The reserved words include `catch`, `continue`, `enum`, `from`, and `provide`, which Lua 5.5 does not reserve, and `global` is always reserved. None of the reserved words can be used as a variable name, a label, a field name after `.` or `:`, or an enum member.

**Tested** (`compile_errors_test.lus`): `local from = 1`, `local provide = 1`, `local enum = 1`, `local global = 1`, and `local catch = 1` all fail with `<name> expected near 'KEYWORD'`. `local continue = 1` fails the same way.

Several words are contextual. They are ordinary names everywhere except in the positions listed here.

| Word | Special meaning | Where |
| --- | --- | --- |
| `const`, `close`, `group` | compile-time attribute names | first token of an attribute inside `< >` (section 5.9) |
| `flags` | reserved pseudo-global | free-name resolution (section 5.11) |
| `where`, `select`, `group`, `having`, `order`, `limit`, `offset` | query clause keywords | between clauses of an `@` query |
| `by`, `as`, `distinct`, `asc`, `desc` | query sub-keywords | inside query clauses and sources |
| `count`, `sum`, `avg`, `min`, `max` | aggregate names | a single name directly followed by `(` inside a query clause |
| `_ENV` | environment upvalue | global name resolution, as in Lua 5.5 |
| `self` | implicit method parameter | bodies of `function a:b()` declarations |

### 1.4 Operators and punctuation

Multi-character tokens:

```
//   ..   ...   ==   >=   <=   ~=   <<   >>   ::
```

Single-character tokens are every other printable non-alphanumeric byte that is not the start of a string, number, or comment. The ones the grammar uses are:

```
+  -  *  /  %  ^  #  &  ~  |  <  >  =  (  )  {  }  [  ]  ;  :  ,  .  ?  @
```

Two single-character tokens have no counterpart in Lua 5.5: `?` (optional chaining) and `@` (query). Each is an ordinary single-character token, and `?` and the suffix after it are separate tokens. Whitespace and comments may therefore appear between them. For example `t ? .a` is valid and means `t?.a`.

The backtick `` ` `` starts an interpolated string (section 1.8). The `$` byte has meaning only inside an interpolated string. Elsewhere it lexes as a single-character token that no grammar rule accepts, so it produces `unexpected symbol near '$'`.

Lexing is greedy. Two consequences matter for Lus syntax.

- `<const>=` lexes as `<`, `const`, `>=`, so `local x <const>= 1` fails with `'>' expected near '>='`. A space is required before `=` after an attribute list.
- `a?.b` lexes as `a`, `?`, `.`, `b`. A numeral such as `?.5` is never formed because `?` is consumed first.

### 1.5 Numerals

**Source:** `syntax/lexer.zig` (`number`, `parseNumber`).

The lexer collects a numeral liberally and then validates it. The collection pattern is:

```
decimal:  digit { digit | '_' | '.' | ( 'E' | 'e' ) [ '+' | '-' ] } [ 'n' | 'd' ]
hex:      '0' ( 'x' | 'X' ) { hexdigit | '_' | '.' | ( 'P' | 'p' ) [ '+' | '-' ] } [ 'n' ]
```

A numeral may also start with `.` when the `.` is directly followed by a digit (`.5`). A sign is accepted only immediately after an exponent mark, so `3-4` is three tokens and `0xe+1` is `0xe`, `+`, `1`. If the collected text is directly followed by a letter, a digit, or an underscore, those characters are swallowed into the numeral to force a validation failure.

An underscore is a digit separator. It must sit between two digits, so `1_000_000` and `0xff_ff` are valid, while `1__0`, `1_`, and `0x_1` are malformed. Separators are removed before the value is read.

A trailing `n` makes the numeral a bigint, and a trailing `d` makes it a decimal. The `n` suffix applies only to integer numerals, decimal or hexadecimal, so `1.5n`, `1e3n`, and `0x1.8n` are malformed. The `d` suffix applies only to decimal notation. In a hexadecimal numeral `d` is a digit, so `0x10d` is the integer 269. A decimal keeps exactly the digits it was written with. It holds at most 131,072 digits before the point and 16,383 after, so `1e131071d` and `1e-16383d` are valid while `1e131072d` and `1e-16384d` are compile errors that report `decimal literal out of range`. **Tested** (`exact_literals_test.lus`): the bigint and decimal forms of the table below, digit separators in both, `0xffd` as an integer, the malformed forms `1.5n`, `1e3n`, `.5n`, `0x1.8n`, `0x1p4n`, `0x1p4d`, `1nn`, `1nd`, `1dn`, `1N`, `1.5D`, `1d5`, `1_n`, `1_d`, and `1ed`, and a round trip through `string.dump`.

The accepted forms after validation are:

| Form | Examples | Value |
| --- | --- | --- |
| decimal integer | `0`, `42`, `1_000` | integer. If it overflows 64 bits it becomes a float (`9223372036854775808` reads as `9.223372036854776e+18`) |
| decimal float | `3.`, `.5`, `1e3`, `1.5e-2` | float |
| hex integer | `0xFF`, `0xffffffffffffffff` | integer, wrapping modulo 2^64 (`0xffffffffffffffff` is `-1`) |
| hex float | `0x1p4`, `0x1.8p1`, `0x.8p1`, `0x1.p3`, `0xA.8p0` | float with a binary exponent |
| bigint | `12n`, `0xffn`, `12345678901234567890123n` | arbitrary precision integer |
| decimal | `1.5d`, `3d`, `1e-2d`, `1.d` | arbitrary precision base 10 number |

Any other collected text raises `malformed number near 'TEXT'`. **Tested** (`lexer_errors_test.lus`): `0x`, `0X`, `1e`, `1e+`, `1e-`, `1.2.3`, `0x1p`, `0x1p+`, `0x.p2`, `3xyz`, and `0b101` are malformed. `0x1p3`, `0x1.8p1`, `0x1.p3`, `0x.8p1`, `1e3`, `1.5e-2`, `.5`, and `0xABCp0` are valid. `1..2` is also malformed because the collector swallows both dots.

### 1.6 Short strings

**Source:** `syntax/lexer.zig` (`shortString`, `escape`), `compile/codegen.zig` (literal validation).

A short string is delimited by `"` or `'` and may not contain an unescaped line break. The escape sequences are:

| Escape | Meaning |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | the usual control bytes |
| `\\` `\"` `\'` | the literal byte |
| `\` followed by a line break | a single `\n` byte (a two-byte break sequence counts once) |
| `\xXX` | exactly two hex digits, one byte |
| `\ddd` | one to three decimal digits, value at most 255. Reading stops after three digits, so `"\65B"` is `"AB"` |
| `\u{X...}` | one or more hex digits, value at most `0x7FFFFFFF`, encoded as extended UTF-8 of up to six bytes. The literal check below accepts code points up to `0x10FFFF` |
| `\z` | skips the following run of whitespace, including line breaks |

Error messages (each ends with `near` followed by the partial string text including the offending escape):

| Message | Cause |
| --- | --- |
| `unfinished string` | a raw line break inside the string. The `near` text is the partial string, such as `'"bad'` |
| `unfinished string near <eof>` | end of input inside the string |
| `invalid escape sequence` | `\` followed by any byte not listed above |
| `hexadecimal digit expected` | `\x` without two hex digits, or `\u{` without a first hex digit |
| `decimal escape too large` | `\ddd` above 255 |
| `missing '{' in \u{xxxx}` | `\u` not followed by `{` |
| `missing '}' in \u{xxxx}` | `\u{...` not closed by `}` right after the digits |
| `UTF-8 value too large` | `\u{...}` above `0x7FFFFFFF` |

After decoding, the compiler checks that the bytes of every string literal (quoted, long, or interpolated) are well formed WTF-8: UTF-8 in which the encoded surrogates `U+D800` to `U+DFFF` are also allowed. A literal that fails the check raises the semantic error `invalid UTF-8 in string literal (use a vector for raw bytes)`. So `"\u{10FFFF}"`, `"\u{D800}"`, and `"\xED\xA0\x80"` are valid, while `"\xff"`, `"\u{110000}"`, and `"\u{7FFFFFFF}"` are rejected. `"\u{80000000}"` fails earlier with `UTF-8 value too large`. Raw bytes belong in vectors.

**Tested** (`lexer_errors_test.lus`): the escapes, their errors, and the literal check. An embedded `\0` is a real character, so `#"a\0b"` is 3.

### 1.7 Long brackets

**Source:** `syntax/lexer.zig` (`longBracketLevel`, `longString`).

A long bracket opener is `[`, then `n` equals signs (n >= 0), then `[`. Its closer is `]`, the same `n` equals signs, then `]`. A long string runs from the opener to the first closer of the same level. Closers of other levels are content. A line break immediately after the opener is dropped. Every line break sequence inside is stored as a single `\n`. No escapes are processed.

An unterminated long string raises `unfinished long string (starting at line N) near <eof>`, where N is the line of the opener. A `[` that does not begin a complete opener is the index token, so `[=x` lexes as `[`, `=`, `x`, and `return [=x` fails with `unexpected symbol near '['`. The content of a long string is subject to the WTF-8 check of section 1.6.

### 1.8 Interpolated strings

**Source:** `syntax/lexer.zig` (`interpSection`, the mode stack), `syntax/parser.zig` (`interpString`).

An interpolated string is delimited by backticks. It may span lines. It contains literal text, `$name` references, and `$(expr)` expressions.

#### 1.8.1 Token stream

The lexer splits an interpolated string into four token kinds. Each carries the literal text of its section (possibly empty) as its semantic value.

| Token | Display name | Lexed at | Means |
| --- | --- | --- | --- |
| `interp_simple` | `<interp_simple>` | opening backtick | the whole string, which has no interpolation |
| `interp_begin` | `<interp_begin>` | opening backtick | literal prefix, then an interpolation follows |
| `interp_mid` | `<interp_mid>` | end of an interpolation | literal text, then another interpolation follows |
| `interp_end` | `<interp_end>` | end of an interpolation | final literal text, then the closing backtick |

The lexer keeps a stack of modes. The bottom mode is ordinary code. Each `$(` pushes a code mode with its own parenthesis depth, so interpolated strings nest to any depth. Lexing proceeds as follows.

1. On `` ` ``, the lexer reads a section (step 3) with the begin kind `interp_begin` and the end kind `interp_simple`.
2. When an interpolation finishes, the lexer reads the next section with the begin kind `interp_mid` and the end kind `interp_end`.
3. Reading a section accumulates literal bytes until one of these occurs:
   - `` ` `` ends the string and returns the end kind.
   - `$$` appends a literal `$`.
   - `$(` returns the begin kind and pushes a code mode with a parenthesis depth of 0.
   - `$` followed by a letter or underscore reads a name `[A-Za-z_][A-Za-z0-9_]*` greedily. A reserved word there raises `invalid interpolation after '$'`. Otherwise the lexer returns the begin kind, then the name as an ordinary `Name` token, and then reads the following section (step 2) at once.
   - `$` followed by anything else raises `invalid interpolation after '$'`.
   - A raw line break appends a single `\n`.
   - End of input raises `unfinished interpolated string near <eof>`.
4. In a pushed code mode, the lexer produces ordinary tokens. Each `(` increments the depth of that mode and each `)` decrements it. A `)` at depth 0 closes the interpolation. The lexer consumes it, pops the mode, reads the next section (step 2), and returns that section's `interp_mid` or `interp_end` token in the position of the `)`. Parentheses inside string literals and comments within the expression are part of those tokens and do not affect the depth. A backtick inside the expression opens a nested interpolated string.

An interpolated section takes every escape of a quoted string (section 1.6), with the same meaning and the same errors, so `` `\27[1m` ``, `` `\x41` ``, `` `\u{e9}` ``, and `` `\z` `` followed by spaces mean what they mean between quotes. Two escapes belong to interpolated strings alone:

| Escape | Meaning |
| --- | --- |
| `` \` `` | literal backtick |
| `\$` | literal `$` |

Quotes need no escaping inside backticks (`` `a'b"c` `` is `a'b"c`), and `\"` and `\'` still mean a quote. An escape that a quoted string rejects, such as `\q`, raises `invalid escape sequence near ...`.

#### 1.8.2 Parsing

```ebnf
interpstring = InterpSimple
             | InterpBegin expr { InterpMid expr } InterpEnd ;
```

Each interpolation is one `expr`. For `$name` the expression is the `Name` token that the lexer emitted, so the parser resolves it as a variable reference (section 5.4). For `$(expr)` the expression is whatever the parser reads up to the closing parenthesis. After each expression the parser requires an `interp_mid` or `interp_end` token. An expression that ends early raises `')' expected near TOKEN`, so `` `$( {1}[1] )` `` fails with `')' expected near '['`, because a constructor takes no suffix.

**Tested** (`compile_errors_test.lus`):

| Source | Result |
| --- | --- |
| `` local s = `abc `` | `unfinished interpolated string near <eof>` |
| `` local s = `abc $( `` | `unexpected symbol near <eof>` |
| `` local s = `abc $( 1 + 2` `` | `unfinished interpolated string near <eof>` (the backtick opens a nested string) |
| `` return `x $()` `` | `unexpected symbol near <interp_end>` |
| `` return `100$` ``, `` return `a $ b` ``, `` return `$1` `` | `invalid interpolation after '$'` |
| `` return `$$` `` | `"$"` |
| `` return `o $( `i` ) o` `` | `"o i o"` |

Nesting works to any depth, so `` return `a $( `b $(1) c` ) d` `` yields `"a b 1 c d"`. A reserved word after `$`, as in `` return `$true` ``, raises `invalid interpolation after '$'`.

### 1.9 Lexical error format

A lexical error message has the form `CHUNK:LINE: MESSAGE near TOKEN`, where `LINE` is the line at which the lexer currently is. For errors raised at the end of input, the `near` part is `near <eof>`. For number and string errors, `TOKEN` is the raw text collected so far in single quotes. A character outside ASCII that no token accepts, such as the `é` of `local é = 1`, fails with `unexpected symbol near 'é'`, which quotes the whole character. Quoted text always runs to the end of the character the lexer stopped in, and each byte of the source that is not part of a UTF-8 character reads as `<\N>` with its decimal value, so `x = 1` followed by the byte 255 fails with `unexpected symbol near '<\255>'`. The `[string "..."]` form of a chunk name cuts a long first line on a character boundary. **Tested** (`lexer_errors_test.lus`, `cli_test.lus`). The interpolation errors `invalid interpolation after '$'` and `invalid escape sequence in interpolated string` carry no `near` part.

---

## 2. Syntactic grammar

**Source:** `syntax/parser.zig`.

This grammar describes what the parser accepts. Semantic restrictions that the parser enforces after syntax (for example that only variables may be assigned) are given in sections 4 and 5. The start symbol is `chunk`.

```ebnf
(* ---------- chunks and blocks ---------- *)

chunk      = block ;

block      = { stat } [ laststat ] ;

laststat   = retstat
           | providestat ;    (* only inside a do-expression, section 5.8 *)

retstat    = 'return' [ explist ] [ ';' ] ;
providestat = 'provide' [ explist ] ;                    (* no ';' *)

(* ---------- statements ---------- *)

stat = ';'
     | label
     | 'break'
     | 'continue'                                        (* section 5.13 *)
     | 'goto' Name
     | 'do' block 'end'
     | 'while' cond 'do' block 'end'
     | 'repeat' block 'until' expr
     | 'if' cond 'then' block { 'elseif' cond 'then' block } [ 'else' block ] 'end'
     | 'for' Name '=' expr ',' expr [ ',' expr ] 'do' block 'end'
     | 'for' Name { ',' Name } 'in' explist 'do' block 'end'
     | 'for' Name { ',' Name } 'from' explist 'do' block 'end'
     | 'function' funcname funcbody
     | 'local' 'function' Name funcbody
     | 'local' localdecl
     | 'global' 'function' Name funcbody
     | 'global' globaldecl
     | catchstat
     | exprstat ;

label      = '::' Name '::' ;

catchstat  = 'catch' [ '[' expr ']' ] expr ;

funcname   = Name { '.' Name } [ ':' Name ] ;

(* ---------- local declarations ---------- *)

localdecl  = attnamelist [ '=' explist | 'from' fromsource ]
           | groupnamelist '=' groupinit { ',' groupinit } ;

attnamelist   = Name [ attribs ] { ',' Name [ attribs ] } ;
groupnamelist = attnamelist ;   (* every name carries the 'group' attribute *)

attribs    = '<' attrib { ',' attrib } '>' ;
attrib     = 'const' | 'close' | 'group'                 (* contextual names *)
           | attrexpr ;
attrexpr   = subexpr(3) ;      (* stops at comparison, 'and', 'or' *)

fromsource = GroupName          (* a Name that resolves to a local group *)
           | expr ;

(* ---------- local groups ---------- *)

groupinit  = groupctor
           | GroupName ;        (* copy of another local group *)

groupctor  = '{' [ groupfield { ( ',' | ';' ) groupfield } [ ',' | ';' ] ] '}' ;
groupfield = Name [ attribs ] '=' ( groupctor | expr ) ;
             (* groupctor only when attribs is <group> *)

(* ---------- global declarations ---------- *)

globaldecl = [ attribs ] '*'
           | [ attribs ] attnamelist [ '=' explist | 'from' expr ] ;

(* ---------- expression statements and assignment ---------- *)

exprstat   = suffixedexp                                 (* must be a call *)
           | varlist '=' explist
           | varlist 'from' fromsource
           | GroupName '=' groupctor ;                   (* group overwrite *)

varlist    = suffixedexp { ',' suffixedexp } ;

(* ---------- conditions with assignment ---------- *)

cond       = assigncond | expr ;

assigncond = Name [ attribs ] { ',' Name [ attribs ] }
             ( '=' explist
             | 'from' fromsource
             | '=' groupinit { ',' groupinit } ) ;       (* all names <group> *)

(* ---------- functions ---------- *)

funcbody   = '(' [ parlist ] ')' block 'end' ;
parlist    = Name { ',' Name } [ ',' varargparam ]
           | varargparam ;
varargparam = '...' [ Name ] ;

(* ---------- expressions ---------- *)

explist    = expr { ',' expr } ;

expr       = subexpr(0) ;

subexpr(L) = ( unop subexpr(12) | simpleexp ) { binop subexpr(R) } ;
             (* loop continues while left priority of binop > L,
                R is the right priority of that binop, see section 3 *)

simpleexp  = Numeral
           | LiteralString
           | interpstring
           | 'nil' | 'true' | 'false'
           | '...'
           | tableconstructor
           | 'function' funcbody
           | catchexp
           | doexp
           | enumexp
           | queryexp
           | suffixedexp ;

catchexp   = 'catch' [ '[' expr ']' ] expr ;
doexp      = 'do' block 'end' ;
enumexp    = 'enum' Name { ',' Name } 'end' ;

suffixedexp = primaryexp { suffix } ;
primaryexp  = Name | '(' expr ')' ;

suffix     = '?'
           | '.' Name
           | '[' expr ']'
           | '[' [ expr ] ',' [ expr ] ']'               (* slice *)
           | ':' Name args
           | args ;

args       = '(' [ explist ] ')' | tableconstructor | LiteralString ;

tableconstructor = '{' [ field { fieldsep field } [ fieldsep ] ] '}' ;
field      = '[' expr ']' '=' expr | Name '=' expr | expr ;
fieldsep   = ',' | ';' ;

unop       = 'not' | '-' | '#' | '~' ;
binop      = 'or' | 'and'
           | '<' | '>' | '<=' | '>=' | '~=' | '=='
           | '|' | '~' | '&' | '<<' | '>>'
           | '..'
           | '+' | '-'
           | '*' | '/' | '//' | '%'
           | '^' ;

(* ---------- queries, section 5.12 ---------- *)

queryexp   = '@' qsource { ',' qsource } { qclause } ;

qsource    = ( Name { '.' Name | '[' ( LiteralString | Integer ) ']' }
             | '(' expr ')' )
             [ 'as' Name ] ;

qclause    = 'where' qexpr
           | 'select' [ 'distinct' ] qitem { ',' qitem }
           | 'group' 'by' qexpr { ',' qexpr }
           | 'having' qexpr
           | 'order' 'by' qorder { ',' qorder }
           | 'limit' qexpr
           | 'offset' qexpr ;

qitem      = qexpr [ 'as' Name ] ;
qorder     = qexpr [ 'asc' | 'desc' ] ;

qexpr(L)   = ( qunop qexpr(12) | qsimple ) { qbinop qexpr(R) } ;
qunop      = '-' | 'not' ;
qbinop     = 'or' | 'and'
           | '<' | '>' | '<=' | '>=' | '~=' | '=='
           | '..' | '+' | '-' | '*' | '/' | '//' | '%' | '^' ;

qsimple    = Numeral | LiteralString | 'nil' | 'true' | 'false'
           | '(' qexpr ')'                    (* no suffix may follow *)
           | aggregate
           | namechain [ hostsuffixes ]
           | hostexp ;

aggregate  = ( 'count' | 'sum' | 'avg' | 'min' | 'max' ) '(' ( '*' | qexpr ) ')' ;
namechain  = Name { '.' Name } ;                         (* at most 10 names *)
hostsuffixes = suffix { suffix } ;  (* first suffix starts with ( [ : ? { or a string *)
hostexp    = simpleexp ;   (* any other expression form, lifted to a host closure *)
```

### 2.1 Disambiguation rules

The grammar above is ambiguous in a few places. The parser resolves each ambiguity with the following rules.

**Statement start.** A statement is dispatched on its first token. `if`, `while`, `do`, `for`, `repeat`, `function`, `local`, `global`, `::`, `return`, `provide`, `break`, `continue`, `catch`, and `goto` each select their own rule. Every other token starts an `exprstat`. Consequently:

- `do` at statement start is always a block statement, never a do-expression. A do-expression can appear only where an expression is expected.
- `catch` at statement start is always a catch statement.
- `enum` and `@` at statement start fail with `unexpected symbol near 'enum'` or `unexpected symbol near '@'`, because `exprstat` begins with `primaryexp`.
- `from` at statement start fails with `unexpected symbol near 'from'`.

**Expression statements.** An `exprstat` begins by parsing one `suffixedexp`. If the next token is `=`, `,`, or `from`, the statement is an assignment. Otherwise the expression must be a plain function call, or the parser raises `syntax error` near the following token.

**Assignment condition detection.** After `if`, `elseif`, or `while`, the condition is an `assigncond` exactly when the current token is a `Name` and one of the following holds.

- The next token is `=`, `,`, or `from`.
- The next token is `<` and the very next source byte after `<` is a letter or underscore.

This is a byte-level peek, so whitespace matters. `if a <b then` is read as an attribute list and fails with `'>' expected near 'then'`, while `if a < b then` is a comparison.

`repeat ... until` takes a plain `expr`. It never accepts an assignment condition.

**Table field versus expression.** Inside a table constructor, a `Name` followed by `=` is a record field. A `Name` followed by anything else starts a list item expression. This uses one token of lookahead.

**Group paths.** When `primaryexp` resolves to a local group variable, the parser enters group mode before the suffix chain. In group mode the next token must be `.` followed by a field name, or `=` (for a group overwrite at statement level). Any other token raises `cannot pass local group`. Group mode continues through subgroup fields and ends at the first ordinary field, after which the regular suffix chain resumes. See section 5.10.

**Group sources after `from`.** If the token after `from` is a `Name` that resolves, in the current function, to a local group, only that `Name` token is consumed and the source is the group. Otherwise the source is a full `expr`.

**Attribute lists versus comparisons in declarations.** After the name in `local`, `global`, a group field, or an assignment condition, a `<` always opens an attribute list. A declaration takes at most one attribute list per name. A second list such as `local x <const> <const> = 1` fails with `unexpected symbol near '<'`.

**Attribute names.** Inside `< >`, an attribute whose first token is the name `const`, `close`, or `group` is the corresponding compile-time attribute and consists of that single token. Every other attribute is parsed as `subexpr(3)`, which accepts arithmetic, bitwise, concatenation, calls, indexing, function literals, and parenthesized expressions, and stops at any comparison operator, `and`, or `or`. **Tested** (`runtime_attrs_test.lus`): `<handlers[1+2]>`, `<function(name, value) return value + 100 end>`, `<(use_doubler and double or triple)>`, `<(handlers.get())>`, `<attrs["my" .. "handler"]>`, and `<handlers[2 | 4]>` all parse.

**Optional chain extent.** A `?` is a suffix like any other. It may appear anywhere in the suffix chain, any number of times, including at the very end (`x = t?`).

**Slice versus index.** After `[`, a leading `,` or a `,` after the first expression makes the bracket a slice. A slice has at most two bound positions, so `t[1, 2, 3]` fails with `']' expected near ','`. Empty brackets `t[]` fail with `unexpected symbol near ']'`.

**Query extent.** A query extends through its sources and then through clauses for as long as the current token is a `Name` that spells a clause keyword. The first token that is not a clause keyword ends the query, whether it is a `Name` (`local q = @t as x where x.a > 1 local y = 2` ends the query at `local`, and a bare `print` would also end it) or any other token. Clause expressions extend as far as `qexpr` reaches.

**Atoms without suffixes.** `simpleexp` alternatives other than `suffixedexp` cannot take suffixes. This includes numerals, all string forms (interpolated strings included), constructors, function literals, `catch`, do-expressions, `enum`, and queries. Wrap such an expression in parentheses to index or call it, as in `("abc"):upper()` or `(enum a, b end).b`. Interpolated strings are not valid call arguments in the string-call form, since `args` accepts only `LiteralString`. `` return f`x` `` fails with `<eof> expected near <interp_simple>`.

**Last statements.** `return` and `provide` end their block. After either, the parser requires a block terminator (`end`, `else`, `elseif`, `until`, or end of input). `return` may be followed by one optional `;`. `provide` may not, so `local x = do provide 1; end` fails with `'end' expected near ';'`. `continue` and `break` are ordinary statements, and statements may follow them.

---

## 3. Operator precedence

**Source:** `syntax/ast.zig` (`BinOp.priority`, `unary_priority`), `syntax/parser.zig` (`subExpr`).

Binary operators are parsed by precedence climbing. Each operator has a left priority and a right priority. `subexpr(limit)` keeps consuming operators whose left priority is greater than `limit`, and parses each right operand with `subexpr(right priority)`. Unary operators parse their operand with `subexpr(12)`.

| Level (low to high) | Operators | Left | Right | Associativity |
| --- | --- | --- | --- | --- |
| 1 | `or` | 1 | 1 | left |
| 2 | `and` | 2 | 2 | left |
| 3 | `<` `>` `<=` `>=` `~=` `==` | 3 | 3 | left |
| 4 | `\|` | 4 | 4 | left |
| 5 | `~` (binary xor) | 5 | 5 | left |
| 6 | `&` | 6 | 6 | left |
| 7 | `<<` `>>` | 7 | 7 | left |
| 8 | `..` | 9 | 8 | right |
| 9 | `+` `-` | 10 | 10 | left |
| 10 | `*` `/` `//` `%` | 11 | 11 | left |
| 11 | unary `not` `#` `-` `~` | | 12 | prefix |
| 12 | `^` | 14 | 13 | right |
| 13 | suffixes `?` `.` `[ ]` `[ , ]` `:` call | | | postfix, part of `suffixedexp` |

Because unary operators parse their operand at priority 12 and `^` has left priority 14, `-x^2` means `-(x^2)` and `2^-3` means `2^(-3)`, exactly as in Lua.

The Lus constructs fit into this table as follows.

- **Suffixes**, including `?` and slices, bind tighter than every operator. `-a?.b` is `-(a?.b)` and `#t[2,]` is `#(t[2,])`.
- **`catch`** is a prefix form whose operand is a full `expr` (`subexpr(0)`). On its left it occupies an operand position like any `simpleexp`. On its right it extends as far as an expression can. `catch a + b` is `catch (a + b)`, `x = 1 + catch f() + 2` is `x = 1 + catch (f() + 2)`, and `not catch x == y` is `not (catch (x == y))`. A comma or closing bracket ends the operand, so `local a, b = catch f(), 2` has two expressions.
- **The handler** in `catch[h]` is a full `expr` delimited by the brackets.
- **Do-expressions, `enum`, and queries** are atoms. They begin with a keyword or sigil and end with `end` (or, for queries, at the first token that cannot continue a clause). `1 + do provide 2 end * 3` is `7`.
- **Attribute expressions** use `subexpr(3)`, which is why comparison operators, `and`, and `or` need parentheses there.
- **Query clause expressions** use the same table with the restrictions listed in section 5.12 (only unary `-` and `not`, no bitwise operators).

---

## 4. Scopes, functions, and control flow

This section summarizes the rules of scopes, functions, and control flow, which match Lua 5.5, together with the details of Lus that touch them. It is not a full restatement of the Lua 5.5 manual.

### 4.1 Scoping and variables

**Source:** `compile/codegen.zig` (`singleVarAux`, `searchVar`).

Lus is lexically scoped. A local declared by `local` enters scope at the statement after its declaration. In `local x = x` the right-hand `x` refers to the outer binding. The variable of `local function f` enters scope before the body, so the function can call itself.

A name resolves by scanning active declarations of the current function from innermost to outermost, then the enclosing functions (creating upvalues), and finally as a global. Global declarations participate in the same scan (section 4.3).

Limits: at most 200 active locals per function (`too many local variables (limit is 200) in main function` or `... in function at line N`), at most 255 upvalues per function (`too many upvalues (limit is 255) in ...`), and at most 255 registers (`too many registers (limit is 255) in ...`). A loop instruction stores the length of its loop in 16 bits, so a `for` loop whose body compiles to more than about 65535 instructions raises `control structure too long`. Hidden internal variables such as the generic-for state slots and runtime attribute slots count toward the local limit. Each name of a `global` statement also takes one of the 200 slots for the rest of its block, so a main chunk that declares ten globals holds at most 190 locals. A function holds at most 65,535 constants and nested functions together, where each distinct string, number, and key of a table constructor counts once, and one more raises `too many constants or functions`. Each argument of a call, value of a `return`, target of a multiple assignment, and segment of an interpolated string occupies a register while the statement runs, so a call in the main chunk passes at most 252 arguments, and a `return`, a multiple assignment, or an interpolated string holds at most 254 values, targets, or segments. A chain of `..` holds at most 199 operands, since each operator nests one syntax level.

### 4.2 Local attributes

**Source:** `syntax/parser.zig` (attribute lists), `compile/codegen.zig` (local statements).

- `<const>` makes the variable read-only. Any assignment to it, from the same function or from a closure, raises `attempt to assign to const variable 'x'` at compile time. If the const variable is the last one in its list, the number of variables equals the number of expressions, it has no runtime attributes, and its initializer is a compile-time constant (`nil`, `true`, `false`, a string literal, a numeral, constant-folded arithmetic, or another compile-time constant), the variable becomes a compile-time constant that occupies no register. A const without an initializer is still read-only (`local x <const> x = 1` is an error).
- `<close>` marks the variable to be closed. At most one per declaration list (`multiple to-be-closed variables in local list`). When the variable goes out of scope, normally or through an error, its `__close` metamethod runs. A value that is neither `nil`, `false`, nor closable raises a runtime error naming the variable (`variable 'x' got a non-closable value`).
- `<group>` declares a local group (section 5.10).
- `<meta>` evaluates the initializer at compile time (section 5.14). It implies `<const>`.
- `<lazy>` defers the initializer to the first read (section 5.15). It implies `<const>`.
- `<observe>` keeps dependents current (section 5.16).
- `<context>` gives the variable a value for each coroutine (section 5.17).
- Combining two different attributes of `<const>`, `<close>`, and `<group>` on one name raises `conflicting attributes`. Repeating the same one inside one list (`<const, const>`) is accepted. `<meta>`, `<lazy>`, `<observe>`, and `<context>` combine with any of them in the parser, and the compiler rejects the combinations that section 5.14 lists.
- Any other attribute is a runtime attribute (section 5.9).

The control variable of a numeric `for` and the first variable of a generic `for` are read-only (`for i = 1, 3 do i = 5 end` raises `attempt to assign to const variable 'i'`). **Tested** (`compile_errors_test.lus`).

### 4.3 Global declarations

**Source:** `compile/codegen.zig` (global statements and name resolution), `vm/interp.zig` (the `already defined` check).

Lus follows the Lua 5.5 global declaration model.

- Every chunk begins with an implicit collective declaration. Until the first explicit `global` statement in scope, any free name is a global variable `_ENV.name`.
- `global name {, name}` declares those names for the rest of the enclosing block. `global *` declares all names collectively. An attribute list before the names or `*` sets the default kind for the whole statement, and an attribute list after a name sets the kind of that name.
- Allowed global attributes are `const` only. `close` raises `global variables cannot be to-be-closed`. `group` raises `global variables cannot be groups`. Any runtime attribute raises `runtime attributes not supported in this context`.
- Name resolution for a free name scans the active declarations from innermost to outermost (continuing into enclosing functions). A matching named declaration makes the name a declared global, read-only if it was declared `<const>`. If no named declaration matches, the innermost collective declaration in scope (if any) decides, and makes the name read-only if that collective declaration was `<const>`. If there is no collective declaration in scope and some named global declaration was passed during the scan, the parser raises `variable 'x' not declared`. If no global declaration of any kind was passed, the implicit declaration applies.
- A collective `global *` anywhere in scope therefore re-enables free names even below a later named declaration.
- The global name `_ENV` is itself resolved as a variable. If it resolves to a global, the compiler raises `_ENV is global when accessing variable 'x'` (for example `global _ENV, x x = 1`).
- The name `flags` is exempt from all of this (section 5.11).

**Tested** (`compile_errors_test.lus`, `global_test.lus`): reads and writes before the first `global` statement are unchecked. After it, any undeclared read or write is an error, including names that were written before the statement. Enforcement ends with the enclosing block. `global *` restores free names. `global 42` fails with `<name> expected near '42'`. `global x.y` fails with `unexpected symbol near '.'`.

Dynamic semantics of initialization:

- `global a, b = e1, e2` evaluates the expression list (adjusted to the number of names) and then, for each name from last to first, checks that the global currently holds `nil` and stores the value. A non-nil current value raises the runtime error `global 'a' already defined`. Because the stores happen last to first, a failure on an earlier name leaves later names already assigned.
- `global a, b` without an initializer generates no code and never raises.
- `global function f() ... end` declares `f`, checks that it is currently `nil` (same runtime error), and stores the closure.
- `global a, b from src` is described in section 5.6.

**Tested** (`global_test.lus`): re-initializing an existing global raises `already defined` and keeps the old value. Redeclaring without initializer never raises. Clearing the global to `nil` allows a later initialization.

### 4.4 Functions and varargs

**Source:** `syntax/parser.zig` (parameter lists), `compile/codegen.zig` (functions).

A parameter list is a list of names optionally ending in `...`. The `...` may be followed by a name (`function f(a, ...t)`), which declares `t` as the vararg table parameter (Lua 5.5). Using `...` in a function that is not vararg raises `cannot use '...' outside a vararg function`. The main chunk is always vararg. A malformed parameter raises `<name> or '...' expected`.

`function a.b:c()` adds an implicit first parameter `self`. Assigning a function to a read-only name (`function flags() end`) raises the const error.

Calls are bounded at run time. The stack of a thread holds at most 1,000,000 slots, so a plain recursive function reaches about 500,000 calls, and one more call raises `stack overflow`. A call that passes through a function written in Zig, such as a callback of `string.gsub` or `table.sort` or a metamethod, nests at most 200 deep, and one more raises `stack overflow (too many nested native calls)`. A coroutine resumed inside a coroutine nests at most 200 deep, and one more raises `C stack overflow`.

### 4.5 Control flow

**Source:** `compile/codegen.zig` (loops, `break`, `continue`, labels).

`break` exits the innermost enclosing loop of the current function, including loops outside an enclosing do-expression (section 5.8). Outside any loop it raises `break outside loop near 'break'`. `continue` follows the same scoping rule and is described in section 5.13. `goto` and labels follow Lua 5.5: a label may not repeat a label visible in the current function (`label 'x' already defined on line N`), an unresolved goto raises `no visible label 'x' for <goto> at line N`, and jumping into the scope of a local raises `<goto x> at line N jumps into the scope of 'y'`.

### 4.6 Multiple results

**Source:** `compile/codegen.zig` (`explist`, `setOneRet`).

Four expression kinds produce a variable number of values: function calls, `...`, `catch` expressions, and do-expressions. They follow one rule. In the last position of an expression list (in `local`, assignment, `return`, call arguments, and table constructors) they produce all their values. In every other position, including inside parentheses and as an operand, they are truncated to exactly one value. The single value of a `catch` is its status. The single value of a do-expression is its first provided value (or `nil`). A call inside an optional chain is always truncated to one value (section 5.2).

---

## 5. Expressions, statements, and declarations

### 5.1 Catch

**Source:** `syntax/parser.zig`, `compile/codegen.zig`, `vm/interp.zig`. **Manual:** `guide.mdx`. **Tests:** `catchstat_test.lus`, `compile_errors_test.lus`.

#### Syntax

```ebnf
catchexp  = 'catch' [ '[' expr ']' ] expr ;   (* expression *)
catchstat = 'catch' [ '[' expr ']' ] expr ;   (* statement *)
```

The operand is any expression, not only a call. `catch nil`, `catch 1 + 2`, `catch t.x`, `catch do ... end`, and `catch (catch f())` are all valid.

#### Static semantics

- A catch at statement start is a catch statement. Everywhere else it is a catch expression.
- The bracketed handler is an arbitrary expression.
- The protected operand may be of any size. An operand of several thousand calls compiles and runs.

#### Dynamic semantics

Evaluation order:

1. If a handler is present, the handler expression is evaluated first, outside the protection. An error while evaluating it propagates.
2. If a handler is present and its value is not a function (a Lus closure or a C function), the runtime raises `attempt to use a TYPE value as a catch handler` at the catch site, outside the protection. A table with a `__call` metamethod is rejected.
3. The operand is evaluated in protected mode.
4. On success, the catch produces `true` followed by the operand's values. A single-valued operand produces exactly one value. A multi-valued operand (a call, `...`, a do-expression, or a nested catch, in tail position of the operand) produces all its values, possibly none. The handler is not called.
5. On failure, any to-be-closed variables opened inside the operand are closed first (an error raised by a `__close` handler replaces the caught error). Then, if a handler is present, it is called with the error object as its only argument, and its first result (or `nil`) replaces the error object. An error raised inside the handler propagates out of the catch. Finally the catch produces exactly two values: `false` and the error object.

The error object keeps its type and identity. A `nil` error payload (`error()` or `error(nil)`) produces the string `"<no error object>"`.

Value counts then follow section 4.6:

| Context | Success | Failure |
| --- | --- | --- |
| last in an expression list | `true, v1, ..., vn` | `false, err` |
| fixed count k (e.g. `local a, b, c = catch f()`) | first k of the above, nil-padded | `false, err`, then nils |
| single value (operand, parentheses, condition, non-last) | `true` | `false` |
| statement | nothing | nothing |

A catch statement evaluates the operand, discards all results, and suppresses any error. With a handler, the handler still runs on failure and its result is discarded. An error in the handler still propagates.

Catches nest and compose with coroutines: a yield inside a protected operand is allowed, and an error raised after resumption is caught by the catch that was active when the operand started.

```lus
local function values()
    return "a", "b", "c"
end

local ok, a, b, c = catch values()  -- true, "a", "b", "c"

local function none()
end

print(select("#", catch none()))  -- 1 (just true)

local ok2, err = catch[function(e)
    return "H", "I"
end] error("x")

-- ok2 == false, err == "H" (extra handler results are dropped)

print((catch error("e")))  -- false
local ok3 = catch f()  -- only the status

catch cleanup()  -- statement form
```

**Tested** (`compile_errors_test.lus`): `catch noop()` for a zero-result `noop` yields `true` and a `nil` second value, with no spurious extra result. **Tested** (`catchstat_test.lus`): side effects before the error persist, registers do not leak across many catch statements or loop iterations, and to-be-closed variables inside the operand are closed on a caught error.

### 5.2 Optional chaining

**Source:** `syntax/parser.zig` (suffix chains), `compile/codegen.zig` (chain evaluation). **Manual:** `guide.mdx`. **Tests:** `optchain_test.lus`, `compile_errors_test.lus`, `syntax_interactions_test.lus`.

#### Syntax

`?` is a postfix suffix that may appear anywhere in a suffix chain:

```lus nocheck
t?.a        t?[k]        t?:m(x)        f?()        t?.list[2,]        t?
```

#### Static semantics

- Once a chain contains a `?`, the whole chain from the first `?` onward is an rvalue. It cannot be an assignment target and it cannot be a call statement. Both forms raise `syntax error` near the next token.

**Tested** (`compile_errors_test.lus`): `t?.a = 1`, `t?[1] = 1`, `t?.a.b = 1`, `h?() = 1`, and `t?.x = 1, 2` all fail with `syntax error near '='`. `local t = {} t?.a` fails with `syntax error near <eof>`.

**Tested** (`optchain_test.lus`, "optional call is an expression, not a statement"): `obj?:process()` and `f?()` as statements fail with `syntax error near <eof>` at the end of a chunk. The statement form is written `local _ = obj?:process()`.

#### Dynamic semantics

The chain is evaluated left to right. The part before the first `?` evaluates normally, so `a.b?.c` raises if `a` is `nil`. At each `?`, the current value is tested for truthiness.

- If the value is `nil` or `false`, evaluation of the rest of the chain is skipped entirely, including any argument expressions of later calls, and the result of the whole chain is that falsy value itself. With `local f = false`, `f?.x` is `false`.
- Otherwise evaluation continues with the next suffix. Suffixes without a preceding `?` are not protected. `t?.a.b` raises if `t.a` is `nil`.
- `?` tests only for `nil` and `false`. Other values are indexed or called normally, so with `local t = true`, `t?.x` raises `attempt to index a boolean value`, and `("str")?.rep` returns `string.rep`.
- A call anywhere after the first `?` produces exactly one value, regardless of context. `print(h?.g())` prints only the first result of `h.g()`, and `select('#', t.x?())` is `1`.
- A trailing `?` with no suffix after it (`t?`) yields the value unchanged. Repeated `?` (`t??.a`) is the same as one.

```lus
local cfg = { db = { host = "localhost" } }
local host = cfg?.db?.host  -- "localhost"
local port = cfg?.server?.port or 8080  -- 8080
local flag = false
assert(flag?.field == false)
local s = nil
assert(s?.list[2,] == nil)  -- the slice is skipped too
```

**Tested** (`syntax_interactions_test.lus`): a nil base suppresses a side-effecting do-expression argument in `x?:m(do ... end)`. `t?.list[2,]` slices when `t.list` exists and raises `attempt to slice a nil value` when `t` exists but `t.list` is nil.

### 5.3 Slices

**Source:** `syntax/parser.zig` (suffix chains), `vm/ext.zig` (the slice operation). **Manual:** `guide.mdx`, `text.mdx`. **Tests:** `slices_test.lus`, `syntax_interactions_test.lus`, `compile_errors_test.lus`.

#### Syntax

```lus nocheck
obj[a, b]     obj[a,]     obj[, b]     obj[,]
```

A slice is a suffix and can appear anywhere an index can, including after `?` and inside longer chains (`t.list[2,4]?[1]`).

#### Static semantics

A slice is an rvalue. **Tested** (`compile_errors_test.lus`): `t[1, 2] = {9, 9}` and `t[,] = 5` fail with `syntax error near '='`, `t[1,], x = 1, 2` fails with `syntax error near ','`, and `t[1, 2, 3]` fails with `']' expected near ','`.

#### Dynamic semantics

The object is evaluated first, then the start bound, then the end bound. An omitted bound is `nil`. Then the slice dispatches on the object's type.

Bound conversion for the built-in slices: `nil` takes the default, an integer is used as is, a float with an exact integer value or a string convertible to such a number is converted, and anything else raises `slice index must be an integer`.

**Strings.** Strings are indexed by character, so the bounds count characters and the length is the character count. The default start is 1 and the default end is the length. The start is raised to 1 if smaller and the end is lowered to the length if larger. Then:

- If the end is below 1 or the start is past the length, the result is the empty string.
- If start > end after clamping, the result is reversed: the characters from start down to end.
- Otherwise the result is the characters from start to end inclusive.

`("hello")[2,4]` is `"ell"`, `("hello")[4,2]` is `"lle"`, `("hello")[-3,2]` is `"he"`, `("hello")[2,100]` is `"ello"`, `("hello")[0,2]` is `"he"`, `("hello")[6,2]` and `("hello")[3,0]` are `""`, and `("héllo")[2,3]` is `"él"`.

**Vectors.** The same rules apply with bytes as the unit, producing a new vector.

**Tables.** If the table has a `__slice` metamethod, it is called as `__slice(t, start, end)` with the raw bound values (including `nil` for omitted bounds, with no conversion) and its first result is the slice. Otherwise the built-in slice applies. The default start is 1 and the default end is the border `#t` (raw length). Bounds are not clamped. If start > end the result is reversed. The result is a fresh table whose element `j` (from 1) is `t[i]` for the `j`-th index `i` walked from start to end in steps of +1 or -1, leaving holes where `t[i]` is absent. A span of more than 2^26 elements raises `slice span too large`. `t[0,2]` on `{1,2,3}` yields a table with `[2] = 1, [3] = 2`.

**Other types.** If the value has a `__slice` metamethod it is called as above. Otherwise the runtime raises `attempt to slice a TYPE value`.

```lus
local t = { 1, 2, 3, 4, 5 }
local a = t[2, 4]  -- {2, 3, 4}
local b = t[, 3]  -- {1, 2, 3}
local c = t[2,]  -- {2, 3, 4, 5}
local d = t[4, 2]  -- {4, 3, 2}
local e = t[,]  -- shallow copy of the sequence
```

**Tested** (`slices_test.lus`): reversed slices produce reversed results, slicing an inline constructor `({...})[a,b]` works, and the result is an independent copy.

### 5.4 String interpolation

**Source:** `syntax/lexer.zig`, `syntax/parser.zig`, `compile/codegen.zig`, `vm/ops.zig` (the conversion to string). **Manual:** `guide.mdx`. **Tests:** `interp_test.lus`, `compile_errors_test.lus`, `syntax_limits_test.lus`, `syntax_interactions_test.lus`.

Lexing is described in section 1.8.

#### Static semantics

- `$name` resolves `name` exactly like a plain variable reference, including global declaration checks. **Tested** (`compile_errors_test.lus`): `global ce_g7 return `value $missingInterpName`` fails with `variable 'missingInterpName' not declared`.
- `$name` takes only the identifier characters. `$t.x` interpolates `t` followed by the literal text `.x`. `$x_1!` interpolates `x_1`.
- A reserved word after `$` is a lexical error. `` `$true` `` and `` `$nil` `` raise `invalid interpolation after '$'`. The literal values are written `` `$(true)` `` and `` `$(nil)` ``.
- Each part occupies a register until the final concatenation, so a string with very many parts can exceed the register limit. **Tested** (`syntax_limits_test.lus`): 255 segments that each interpolate an integer literal compile, and 400 fail with `too many registers`.

#### Dynamic semantics

Parts are processed left to right. Each non-empty literal section becomes a string constant. Each `$name` or `$(expr)` is evaluated and immediately converted to a string before the next part is evaluated. `$(expr)` is truncated to one value. The conversion is the internal `tostring` operation, independent of the global `tostring`:

- strings are used as is,
- integers and floats use the standard number formatting (`1.0` stays `"1.0"`),
- `nil`, `true`, and `false` become `"nil"`, `"true"`, `"false"`,
- any other value with a `__tostring` metamethod calls it. A string result is used as is, and a number result is converted as above. Any other result raises `'__tostring' must return a string`.
- any other value becomes `"TYPENAME: 0xADDRESS"`, where `TYPENAME` honors `__name`.

The result is the concatenation of all parts in order. An empty interpolated string is `""`. A string with only literal text is that text.

```lus
local name, age = "Alice", 30
print(`Hello, $name!`)  -- Hello, Alice!
print(`Next year: $(age + 1).`)  -- Next year: 31.
print(`$$5 and \`ticks\``)  -- $5 and `ticks`
print(`$(nil) $(1.0)`)  -- nil 1.0
```

**Tested** (`interp_test.lus`): interpolation works when the global `tostring` is `nil` or shadowed. **Tested** (`syntax_interactions_test.lus`): a yield inside an interpolated expression resumes correctly, a do-expression inside `$(...)` providing two values renders the first, and one without `provide` renders `nil`.

### 5.5 Enums

**Source:** `syntax/parser.zig` (`enum` expressions), `compile/codegen.zig`, `vm/ext.zig`. **Manual:** `guide.mdx`. **Tests:** `enum_test.lus`, `compile_errors_test.lus`, `syntax_limits_test.lus`.

#### Syntax

```ebnf
enumexp = 'enum' Name { ',' Name } 'end' ;
```

#### Static semantics

- `enum` is an expression only. **Tested**: `enum a, b end` as a statement fails with `unexpected symbol near 'enum'`.
- At least one member is required. Members are names (reserved words are rejected). A trailing comma is rejected.
- Duplicate members raise `duplicate enum member 'a'`.
- At most 255 members (`too many names in enum near TOKEN`). **Tested** (`syntax_limits_test.lus`): 255 compile, 256 fail.
- The closing `end` error is always the short form `'end' expected near TOKEN`.

**Tested** (`compile_errors_test.lus`):

| Source | Message |
| --- | --- |
| `local e = enum end` | `<name> expected near 'end'` |
| `local e = enum a, b, end` | `<name> expected near 'end'` |
| `local e = enum , end` | `<name> expected near ','` |
| `local e = enum a b end` | `'end' expected near 'b'` |
| `local e = enum 1, 2 end` | `<name> expected near '1'` |
| `local e = enum while end` | `<name> expected near 'while'` |
| `local e = enum nil end` | `<name> expected near 'nil'` |

#### Dynamic semantics

An `enum` expression is a constant of the enclosing function. Every evaluation of the same `enum ... end` expression (for example in a loop or across calls of the same function) yields the identical enum, while two textually distinct `enum` expressions always yield distinct enums even with the same member names.

The value of the expression is the first member. Members support indexing by name and by 1-based position from any member of the same enum (`e.x.y == e.y`, `e[1][3] == e.z`), ordering comparisons within one enum (comparing members of different enums raises), equality by identity, `tonumber` giving the 1-based position, `type` giving `"enum"`, and use as table keys.

```lus
local color = enum red, green, blue end
assert(color == color.red)
assert(color[2] == color.green)
assert(color.red < color.blue)
assert(tonumber(color.blue) == 3)
```

### 5.6 `from` destructuring

**Source:** `syntax/parser.zig`, `compile/codegen.zig` (`from` in local, global, assignment, and condition forms). **Manual:** `guide.mdx`. **Tests:** `from_test.lus`, `compile_errors_test.lus`, `syntax_interactions_test.lus`, `groups_test.lus`.

#### Syntax

```lus nocheck
local a, b, c from src          -- local declaration
global a, b from src            -- global declaration
a, b from src                   -- assignment to existing variables
if a, b from src then ... end   -- assignment condition (also elseif, while)
```

#### Static semantics

- The names select the fields. `local x, y from t` reads `t.x` and `t.y`.
- **Local form.** Compile-time attributes on the names are allowed except `close` (`cannot use 'from' with to-be-closed variables`). A `<const>` name becomes read-only (never a compile-time constant). Runtime attributes raise `runtime attributes not supported with 'from'`. A `<group>` name switches the statement to the group path, which requires `=` (so `from` there fails with `'=' expected near 'from'`).
- **Assignment-condition form.** `<group>` names raise `cannot use 'from' with <group> variables`, `<close>` names raise `cannot use 'from' with to-be-closed variables`, and runtime attributes raise `runtime attributes not supported in this context`.
- **Global form.** Attribute rules of section 4.3 apply.
- **Assignment form.** Each target must be a local, an upvalue, a local group field, or a global accessed through the `_ENV` upvalue. Any other target (a field `t.x`, an index, a global accessed through a local `_ENV`) raises `'from' requires simple variable names`. Read-only targets raise the const error. The field name used for a group field target is the field's name.
- **Group source.** When the token after `from` is a name that resolves to a local group in the current function, the source is that group and only the name is consumed. Each target name must be a non-subgroup field of the group (`'z' is not a field of group 'g'`, `cannot deconstruct subgroup 'c' with 'from'`).
- The assignment form accepts every global target reached through the `_ENV` upvalue, in any position. `x, y from {x=1, y=2}` as the first statement of a chunk assigns both globals.

**Tested** (`compile_errors_test.lus`): `t.x from s` fails with `'from' requires simple variable names`. `local a from` fails with `unexpected symbol near <eof>`. `local from t` fails with `<name> expected near 'from'`. `from x` fails with `unexpected symbol near 'from'`. `local a, from {a=1}` fails with `<name> expected near 'from'`.

#### Dynamic semantics

1. The source expression is evaluated exactly once.
2. For each name from left to right, the field `src.name` is read with a normal indexed read, so `__index` applies. A missing field yields `nil`. A `nil` or non-indexable source raises the usual `attempt to index` error.
3. The values are then bound.
   - Local form: the new locals receive the values in order and enter scope.
   - Global form: for each name from last to first, the `already defined` check of section 4.3 runs and the value is stored.
   - Assignment form: the values are stored into the targets from last to first. Runtime attribute handlers on local targets run during these stores, so they fire in reverse name order.
   - Assignment-condition form: the locals are declared, then the condition is true exactly when every value is truthy.
4. With a group source, step 2 copies the current field values of the group.

```lus
local t = setmetatable({}, {
    __index = function(_, k)
        return k .. "!"
    end,
})

local p, q from t  -- p == "p!", q == "q!"
local cfg = { host = "h", port = 1 }
local port, host from cfg  -- order of names is free
local x, y
x, y from { x = 1, y = 2 }
```

**Tested** (`from_test.lus`): the source expression runs once even when extracting several fields, the array part is ignored, and missing fields become `nil`. **Tested** (`syntax_interactions_test.lus`): `local a from nil` raises under `catch`, and `while x from t do ... end` drains a field until it becomes `nil`.

#### The `for ... from` loop

`for a, b, c from explist do block end` is a generic `for` whose items are destructured. The explist produces the iterator, the state, the initial control value, and the closing value, as for `in`. Before each pass the loop calls the iterator with the state and the control value and keeps its first result, the _record_. The record is the new control value. If it is `nil`, the loop ends. Otherwise each name, from left to right, receives `record.name` through a normal indexed read, so `__index` applies, a missing field yields `nil`, and a record that cannot be indexed raises `'for ... from' needs an iterator that yields tables, got a number value` with the type of the record. A string record reads fields of the `string` library, as any index of a string does, so `for x from io.lines()` gives `nil` names without an error.

- The names are fresh locals of each pass and may be assigned. Closures capture the variable of their own pass.
- The record occupies a hidden read-only local. The names are fields, so the order of names is free and their number is not limited by the iterator's results.
- The loop builds no table. Each pass costs the iterator call and one field read per name, the same as a generic `for` whose body copies the fields by hand (`tests/bench/forfrom.lus`).
- `break`, `continue`, labels, and the closing value behave as in a generic `for`.
- `from` is for iterators that yield records. An iterator whose first result is an index or a key, such as the one `ipairs` or `pairs` returns, raises the error above on the first pass.

**Tested** (`forfrom_test.lus`): fields read by name in any order, missing fields as `nil`, `__index` on records, fresh assignable variables per pass, `break` and `continue`, nested loops, query rows, a non-indexable record, an empty iteration, the closing value, a coroutine iterator, and the syntax errors.

### 5.7 Assignment conditions in `if`, `elseif`, and `while`

**Source:** `syntax/parser.zig` (conditions), `compile/codegen.zig` (`ifStat`, `while` loops). **Manual:** `guide.mdx`. **Tests:** `ifassign_test.lus`, `whileassign_test.lus`, `syntax_interactions_test.lus`, `compile_errors_test.lus`, `attrs2_test.lus`.

#### Syntax

```ebnf
assigncond = Name [ attribs ] { ',' Name [ attribs ] }
             ( '=' explist | 'from' fromsource | '=' groupinit { ',' groupinit } ) ;
```

Detection is described in section 2.1.

#### Static semantics

- The names are new local variables. In an `if` statement, the whole statement is wrapped in one scope, so variables declared in the `if` condition or any `elseif` condition are visible in that clause's block and in every later `elseif` condition, `elseif` block, and `else` block. They are not visible after `end`.
- In a `while` statement, the loop is wrapped in one scope that is entered once. The condition variables are visible in the body and are a single binding shared by all iterations.
- Compile-time attributes are allowed: `<const>`, `<close>` (at most one per condition, `multiple to-be-closed variables in condition`), and `<group>`. Runtime attributes raise `runtime attributes not supported in this context`.
- If any name is `<group>`, every value is parsed as a group constructor or a group name, and every name must be `<group>` (`cannot mix <group> with non-group variables in condition`). `<close>` cannot be combined with `<group>` (`conflicting attributes`). Group conditions are always true.

**Tested** (`compile_errors_test.lus`):

| Source | Message |
| --- | --- |
| `if x = then end` | `unexpected symbol near 'then'` |
| `if = f() then end` | `unexpected symbol near '='` |
| `if x = 1 end` | `'then' expected near 'end'` |
| `if x, = 1 then end` | `<name> expected near '='` |
| `while x = do end` | `'do' expected near <eof>` (the `do` is consumed as a do-expression) |
| `while x, = f() do end` | `<name> expected near '='` |

#### Dynamic semantics

1. The expression list is evaluated and adjusted to the number of names, exactly like a `local` statement. With `from`, section 5.6 applies.
2. The variables are bound.
3. The condition is true exactly when every variable holds a truthy value (not `nil` and not `false`). The tests run in name order and stop at the first falsy value.
4. For `while`, steps 1 to 3 are repeated before each iteration, assigning the same variables again. After a normal exit the variables hold the final, falsy values.

Because the `while` variables are one binding, closures created in different iterations share them. **Tested** (`syntax_interactions_test.lus`): closures created in a while-assignment loop all observe the value at break time, or the final falsy value after normal exit, and a body-local copy restores per-iteration capture. Closures over `if` condition variables capture the value of that `if` statement.

```lus nocheck
if user = find(id) then
    greet(user)
elseif guest = defaultGuest() then
    greet(guest)            -- user (nil) and guest both visible
else
    print(user, guest)      -- both visible, both falsy
end

while line = file:read() do
    process(line)
end

if ok, value = catch risky() then use(value) else report(value) end
```

### 5.8 Do-expressions and `provide`

**Source:** `syntax/parser.zig`, `compile/codegen.zig` (do-expressions and `provide`). **Manual:** `guide.mdx`. **Tests:** `doexpr_test.lus`, `compile_errors_test.lus`, `syntax_interactions_test.lus`, `syntax_limits_test.lus`.

#### Syntax

```ebnf
doexp       = 'do' block 'end' ;            (* only in expression position *)
providestat = 'provide' [ explist ] ;       (* must be the last statement of its block *)
```

#### Static semantics

- `do` in expression position is a do-expression. `do` at statement start is a plain block (section 2.1).
- `provide` is valid anywhere inside the body of a do-expression of the same function, at any block depth, including inside loops and `if` branches. The innermost enclosing do-expression is the target. Outside a do-expression, including directly inside a plain `do` statement and inside a function literal nested in a do-expression, it raises `'provide' outside do expression near 'provide'`.
- `provide` ends its block. A statement after it raises `'end' expected near TOKEN` (or the corresponding block terminator message). `provide` takes no trailing `;`.
- The body is an ordinary scope. Locals declared inside are not visible outside.
- `break`, `continue`, `goto`, and `return` inside a do-expression behave as in any block: `break` and `continue` may act on a loop outside the do-expression, `goto` may jump to a label outside, and `return` returns from the enclosing function. The do-expression then produces no value.

**Tested** (`compile_errors_test.lus`): `provide 1`, `do provide 1 end`, and `local x = do local f = function() provide 1 end provide 2 end` fail with `'provide' outside do expression near 'provide'`. `local x = do provide 1 local y = 2 end` fails with `'end' expected near 'local'`. `local x = do provide 1 provide 2 end` fails with `'end' expected near 'provide'`. `local x = do for i = 1, 2 do provide i end end` compiles and yields 1.

#### Dynamic semantics

1. The result slot is set to `nil`.
2. The body runs.
3. When a `provide` executes, its expression list is evaluated (a trailing call, `...`, catch, or do-expression keeps all its values). All upvalues and to-be-closed variables of the do-expression body (and of the inner blocks being exited) are closed, then the provided values become the result and control leaves the do-expression.
4. If the body completes without executing `provide`, its variables are closed and the result is a single `nil`. An empty `provide` also produces a single `nil`. A `provide f()` where `f` returns nothing produces zero values.
5. The result count is then adjusted by context (section 4.6).

```lus
local x = do
    local y = 10
    provide y * 2
end  -- 20

local a, b = do  -- 1, 2
    provide 1, 2
end

local n = 1 + do  -- 7
    provide 2
end * 3

local ok, v = catch do
    provide risky()
end

local w = do
    for i = 1, 10 do
        if i * i > 20 then
            provide i
        end
    end

    provide -1
end  -- 5
```

**Tested** (`doexpr_test.lus`): nested do-expressions to three levels, provide in either branch of an `if`, early provide from a loop, fewer or more provided values than targets, and access to and mutation of outer locals and upvalues. **Tested** (`syntax_limits_test.lus`): very deep nesting fails gracefully with `chunk has too many syntax levels (stack overflow)`.

A group initializer is a constructor or a group name (section 5.10), so `local x <group> = do provide 1 end` fails with `unexpected symbol near 'do'`.

### 5.9 Attributes

**Source:** `syntax/parser.zig` (attribute lists), `compile/codegen.zig` (attribute checks and handler calls). **Manual:** `guide.mdx`. **Tests:** `runtime_attrs_test.lus`, `attrs2_test.lus`, `compile_errors_test.lus`.

#### Syntax

```ebnf
attribs  = '<' attrib { ',' attrib } '>' ;
attrib   = 'const' | 'close' | 'group' | subexpr(3) ;
```

The attribute list follows the variable name, as in `local n <only "number"> = 10`.

#### Where each kind is allowed

| Position | Compile-time | Runtime |
| --- | --- | --- |
| `local` with one name and `=` or no initializer | yes | yes |
| `local` with several names | yes | `runtime attributes not supported with multiple variables` |
| `local ... from` | `const`, `group` path | `runtime attributes not supported with 'from'` |
| `local g <group, h> = { ... }` | yes | yes, applied to the direct fields (see 5.10) |
| group fields | yes | `runtime attributes not supported in this context` |
| assignment conditions | yes | `runtime attributes not supported in this context` |
| `global` (prefix and per name) | `const` only | `runtime attributes not supported in this context` |
| `for` variables, parameters | no attribute syntax | no attribute syntax |

Compile-time attributes must come before runtime attributes in one list. **Tested** (`attrs2_test.lus`): `<h, const>` fails with `compile-time attribute 'const' must come before runtime attributes`, and `<h, close>` fails similarly with `'close'`.

#### Static semantics of runtime attributes

- Each runtime attribute expression is compiled at the declaration, before the initializer, into a hidden local named `(attr)`. These hidden locals stay alive for the rest of the block and count toward the local limit.
- An attribute name of `const`, `close`, or `group` always means the compile-time attribute. A runtime attribute cannot be a variable with one of those names unless the expression begins differently (for example `<(const)>`).
- In a context that rejects runtime attributes, the expression is still parsed before the error is raised.

#### Dynamic semantics of runtime attributes

Handler invocation for a value `v` stored into variable `x` with handlers `h1, ..., hn`:

1. If `v` is `nil` (raw comparison), no handler runs and `nil` is stored.
2. Otherwise, for each handler in declaration order, call `hi("x", v)` with one result. If the result is not `nil`, it becomes the new `v`. A `nil` result keeps the previous `v`. A `false` result becomes `false` and later handlers receive `false`. Extra results are ignored.
3. The final `v` is stored.

A handler that is not callable raises the normal call error at the declaration (the message names the `(attr)` slot). An error in a handler propagates, and the variable keeps its previous value. Handlers may yield.

Handlers run on:

- the initialization of the attributed local (only if an initializer is present and its value is not `nil`),
- every assignment statement whose target is the attributed local itself, in the function that declares it (single assignment, multiple assignment, and `from` assignment),
- the initialization and direct field assignment `g.f = v` of the direct fields of a group declared with runtime attributes, with the name `"g.f"`.

Handlers do not run on:

- assignments made from a nested function through an upvalue (the value is stored as written),
- a group overwrite `g = { f = v }` (the fields are stored directly),
- the fields of a subgroup of an attributed group, at initialization or on assignment.

Ordering with `<close>` and `<const>`: with `<close, h>`, the handler runs on initialization and then the resulting value is marked to be closed. With `<const, h>`, the handler runs on the single initialization and the variable is a register-held read-only local.

```lus
local function only(kind)
    return function(name, value)
        if type(value) ~= kind then
            error(`$name: expected $kind`)
        end

        return value
    end
end

local n <only "number"> = 10
n = 20  -- checked
n = nil  -- handler skipped

local function first(name, v)
    return v + 1
end

local function second(name, v)
    return v * 2
end

local x <first, second> = 10  -- 22
```

**Tested** (`attrs2_test.lus`): the attribute expression runs exactly once and before the initializer, a declaration without initializer skips the handler, shadowed attributed locals dispatch to their own handlers, an upvalue write from a closure does not re-invoke the handler, and a handler returning `false` sets the variable to `false`.

### 5.10 Local groups

**Source:** `syntax/parser.zig` (group constructors), `compile/codegen.zig` (`groupPath` and the group forms of the local, assignment, condition, and `from` statements). **Manual:** `guide.mdx`. **Tests:** `groups_test.lus`, `compile_errors_test.lus`, `attrs2_test.lus`, `from_test.lus`.

#### Syntax

```lus
local z <group> = { a = 1, b <const> = 2, c <group> = { d = 3 } }
local y <group> = z  -- copy
z = { a = 10 }  -- overwrite of listed fields
z.a = 5  -- field assignment
print(z.c.d)  -- subgroup field
local a, b from z  -- group source
```

#### Static semantics

- A group is a compile-time namespace. Each non-subgroup field is a real local variable that holds the field value. The group name itself has no runtime value. Field locals are reachable only through a group path, so after `local z <group> = { a = 1 }` a plain `a` still resolves to whatever `a` was in scope before.
- In a `local` statement, if any name is `<group>`, every initializer is parsed as a group constructor or a group name, and every name must be `<group>` (`cannot mix <group> with non-group variables`). `<close>` cannot be combined with `<group>` (`conflicting attributes`), and `=` is required. Several groups may be declared in one statement, separated by commas. Any other initializer, such as `local a <group> = 5`, fails with `unexpected symbol near '5'`.
- A group constructor contains only `Name [attribs] = value` fields. Separators `,` or `;` are required between fields and a trailing separator is allowed (`expected ',' or ';' in group constructor`). A `<group>` field takes a nested constructor and declares a subgroup. Bracketed keys and positional items are rejected with `<name> expected near TOKEN`. **Tested** (`compile_errors_test.lus`): `{ [1] = 2 }` fails with `<name> expected near '['` and `{ 1, 2 }` fails with `<name> expected near '1'`.
- A group name is usable only as the prefix of a field path (`g.f`, `g.sub.f`), as the target of a group overwrite, as the value of another group's initializer, and as a `from` source. Anywhere else, including as a call argument, after `?`, or alone, it raises `cannot pass local group`. A group-copy initializer that is not a group name raises `group can only be copied from another group`.
- A field path naming an absent field raises `'f' is not a field of group 'g'`, for reads and writes alike.
- `<const>` fields reject assignment with the const error. **Tested**: `local z <group> = { a = 1, b <const> = 2 } z.b = 3` fails with `attempt to assign to const variable 'b'`.
- A group overwrite `g = { ... }` accepts only a constructor (`group can only be assigned a constructor or another group`), and every listed field must already exist (`'d' is not a field of group 'z'`). Subgroups cannot be overwritten (`cannot overwrite subgroups`). Fields are separated by `,` or `;`, so `z = { a = 1 a = 2 }` fails with `'}' expected near 'a'`.
- Groups are always local. `global g <group>` raises `global variables cannot be groups`.
- Group names resolve lexically to the innermost group in scope. In `local g <group> = {a=1} do local g <group> = {b=2} end print(g.a)`, the last `g.a` names the field of the outer group.
- A nested function reaches the fields of a group declared in an enclosing function through the same group paths. Each field it names becomes an upvalue of the nested function that refers to the field local, so reads and writes on either side see one variable, exactly as for a captured ordinary local. Overwrites, copies, and `from` sources work the same way inside the nested function. **Tested** (`groups_test.lus`): a closure created in each loop iteration captures that iteration's field.
- A field declared `<close>` is read-only and is never closed. A value that needs closing belongs in an ordinary `<close>` local.

#### Dynamic semantics

- Initialization evaluates field values in source order and stores each into its field local.
- A copy `local y <group> = z` copies the current values of `z`'s non-subgroup fields into new locals. Subgroup fields of `y` refer to the same field locals as `z`'s subgroups, so after the copy, `y.c.d = 42` also changes `z.c.d`.
- An overwrite evaluates each listed value in source order and stores it into the existing field. Unlisted fields keep their values.
- With runtime attributes on the group (`local g <group, h> = {...}`), handlers run for each direct field as described in section 5.9.

A group takes one slot of the local limit besides one slot for each field, so a function with no other locals holds a group of at most 199 fields.

### 5.11 Flags and compile-time folding

**Source:** `compile/codegen.zig` (`foldFlag`, `foldFlagCond`, `ifStat`, `discardBlock`, `discardCond`), `main.zig` (option `-F`), `api.zig` (`setFlags`). **Manual:** `guide.mdx`. **Tests:** `flags_test.lus`.

#### The `flags` table

The CLI options `-F NAME`, `-FNAME`, `-F NAME=VALUE`, and `--flag NAME[=VALUE]` populate a read-only table exposed as the global `flags`. A flag without `=` is `true`. A value that parses as a numeral becomes a number. Any other value, including an empty one, becomes a string. A repeated flag keeps its last value. The table always exists when `lus` runs a script, even without flags. Workers see the same table. `lus build` and `lus compile` accept the same `-F` options and fold with them.

#### Static semantics of the name `flags`

- `flags` is a reserved pseudo-global. A free reference to `flags` is always allowed, even under a strict `global` declaration.
- Assigning to the free name raises `attempt to assign to const variable 'flags'`. This includes `function flags() end`.
- Declaring it as a global raises `cannot declare 'flags' (reserved name)`. This includes `global flags`, `global function flags`, and any other global declaration form.
- Locals may shadow it. `local flags = {}` is valid, and a shadowed `flags` never folds.
- Writing a field (`flags.x = 1`) compiles and fails at runtime with `attempt to modify a readonly table`.

#### Folding

Folding applies to the condition of an `if` or `elseif` clause when the condition is a plain expression (not an assignment condition) whose value is known at compile time, and the compiler evaluates compile-time code (`lus check`, `lus fmt`, `lus ast`, `debug.parse`, and `debug.format` do not, and fold flag conditions only). `spec/design/meta.md`, section 4, defines the conditions known at compile time: literals, flag reads, `<meta>` locals, `<const>` compile-time constants, fields of these, operators, and calls of a fixed set of pure library functions. A flag read is `flags.NAME` or `flags["NAME"]` where `flags` is the free reserved name, and it is known only when the compiling state has a flags table (`lus`, `lus build`, and `lus compile` create one, and a bare embedding has none). A flag is true when it is present and truthy.

A condition folds to the result the program would compute. Equality follows raw equality, so `flags.count == 3.0` is true for the flag value `3`. Ordering of two strings compares their bytes. A condition whose evaluation raises an error, such as `flags.absent < 3` or `string.rep("x", 1e10)`, does not fold and runs normally.

An `and` folds when its left operand folds false, or when both operands fold. An `or` folds when its left operand folds true, or when both operands fold. A right operand that folding skips would not run at runtime either, so folding never removes an evaluation that a run performs. A condition whose left operand folds and does not decide the result, such as `flags.debug and verbose` with the flag set, compiles normally. `while`, `repeat`, and expressions outside conditions never fold.

- A folded condition is compiled for checking and then discarded, so an operand that folding skipped still reports its compile errors.
- If a clause folds false, its block is fully parsed and checked and then its generated code is discarded. Evaluation continues with the next clause.
- If a clause folds true, its block is compiled normally and every later `elseif` and `else` clause is fully parsed and checked and then discarded.
- Discarded code leaves no trace: no instructions, no pending `break`, `continue`, `goto`, or `provide` targets, no labels, no nested prototypes, no debug locals, and correct line information afterwards. A `<meta>` initializer in discarded code is never evaluated. Constants and upvalues created while parsing a discarded block may remain in the function (this is invisible to programs).
- Folding decisions are made at compile time with the flags of the compiling process and are baked into dumped bytecode.

```lus nocheck
-- lus -Fdebug -Fchannel=beta -Flevel=3 script.lus
if flags.debug then
    enableTracing()        -- compiled
else
    quiet()                -- parsed, checked, discarded
end
if flags.channel == "beta" and flags.level >= 2 then
    print("beta")          -- compiled without a test
end
if flags.debug and verbose then   -- not foldable, runtime test of verbose
    print("verbose")
end
```

**Tested** (`flags_test.lus`): dead branches are still syntax checked, line numbers stay correct after folded branches, a `break` inside a dead branch does not affect the loop, closures and `<close>` locals in dead branches do not disturb live code, a `goto` in a dead branch is dropped, nested folds work, the folded chunk is much smaller than the unfolded control, comparisons with literals fold, `and`, `or`, and `not` combine folds, a deciding left operand folds alone and skips the right one, comparisons that raise or depend on runtime values keep their runtime behavior, and operands skipped by folding are still checked. The differential tester (`tests/diff`) runs every generated program with fixed flags and again with every flag read through a local, which never folds, and the two runs must agree.

### 5.12 Queries

**Source:** `syntax/parser.zig` (queries and clause expressions), `compile/query_gen.zig` (plan generation), `vm/query.zig` (the query value and engine). **Manual:** `guide.mdx`. **Tests:** `query_test.lus`, `sqlite_test.lus`.

#### Syntax

The grammar is in section 2. A query begins with `@`, lists one or more comma-separated sources, and continues with clauses in any order.

```lus
local adults = @people as p where p.age > 18 select p.name, p.age order by p.age desc limit 100
```

#### Static semantics: sources

- A source is a name chain with optional `.Name` fields and `[literal]` indices, or a parenthesized expression. The index literal must be a string literal or a non-negative integer literal (`query source index must be a literal`).
- The source value is evaluated once, in the enclosing scope, when the query value is built. Name resolution follows normal rules, including global declaration checks.
- Each source binds a row variable. The alias is the `as Name` if given, otherwise the last plain name of the chain. A source ending in an index or a parenthesized source requires `as` (`query source needs an 'as' name`). Aliases must be distinct within the query (`duplicate row variable 'x' in query`). Row variables exist only inside the query's clauses and never enter the enclosing scope.
- At most 8 sources (`too many sources in query`). Two or more sources form a join, which requires a `select` clause (`a join requires a 'select' clause`).

#### Static semantics: clauses

- Each clause appears at most once (`duplicate 'where' clause in query`, and likewise for `select`, `group`, `having`, `order`, `limit`, `offset`).
- `group` and `order` require `by` (`'by' expected after 'group'`, `'by' expected after 'order'`).
- `select [distinct] item {, item}`: each item is a clause expression with an optional `as Name`. Without `as`, a bare row variable passes the whole row through, and a `row.column` item is named after the column. Any other item requires `as` (`'as' name expected for this projection`). At most 32 items.
- `order by item [asc | desc] {, ...}`: default ascending. Inside `order by`, a bare single name that is not a row variable refers to a projection alias, even if a local of that name exists. At most 16 items.
- `group by expr {, expr}`: at most 16 keys.
- `limit expr` and `offset expr`: the expression may not depend on a row (it may not use row variables, columns, host closures, alias references, or aggregates). Otherwise `query limit must be row-independent` or `query offset must be row-independent`.
- Aggregates `count`, `sum`, `avg`, `min`, `max` are recognized when the name is a single name directly followed by `(`. They are allowed only in `select` and `having` (`aggregate 'sum' is only allowed in 'select' or 'having'`), cannot nest (`aggregates cannot nest`), and only `count` accepts `*` (`'*' is only allowed in count`). This recognition happens before name resolution, so a local function named `count` cannot be called by that name inside a clause.

#### Static semantics: clause expressions

Clause expressions are reified into plan nodes that the query engine interprets. The accepted forms and their treatment:

| Form | Treatment |
| --- | --- |
| integer, float, string, `nil`, `true`, `false` | literal node |
| `row` (a row variable alone) | row reference |
| `row.column` | column reference |
| `name` or `name.f.g` not starting with a row variable | bound parameter, evaluated once at build time in the enclosing scope (at most 10 names in a chain) |
| `( qexpr )` | grouping. A suffix after the closing parenthesis raises `a suffix on a parenthesized expression is not supported in a query clause` |
| unary `-`, `not` | arithmetic and logical nodes |
| `+ - * / // % ^`, `..`, comparisons, `and`, `or` | binary nodes with standard precedence |
| aggregate call | aggregate node |
| `row.a.b` (a row chain deeper than one field) | host closure |
| a name chain followed by `(`, `[`, `:`, `?`, `{`, or a string | host closure that resumes the full suffix chain |
| any other expression (constructor, function literal, interpolated string, `catch`, do-expression, `enum`) | host closure |

A host closure is a child function whose parameters are the row variables in source order. It is compiled with the ordinary expression machinery, so upvalues are live and every suffix form works inside it. It runs per row at query execution time. A `...` inside a host closure fails because the closure is not vararg.

Rejected forms: unary `#` and `~`, and binary `&`, `|`, `~`, `<<`, `>>` raise `operator not supported in a query clause`. A nested `@` anywhere inside a query, including inside a host closure, raises `nested queries are not supported`.

Complexity limits raise `query too complex`. The parser checks 32 select items, 16 group keys, 16 order items, and 10 names per chain at compile time. Building the query value checks the limit of 200 operands (parameters plus host closures).

A `where` clause may hold any number of top-level `and` conjuncts. The plan lists the first 255 separately and joins the rest into one final conjunct, and only the first 63 may be pushed down to a provider. Both bounds keep the condition and its evaluation order. **Tested** (`query_test.lus`): `where` clauses of 63 to 1000 conjuncts filter tables and SQLite sources alike.

The parser also bounds the nesting depth of clause expressions. A clause expression nested too deeply raises `query too complex` at compile time.

A bare column is a valid clause expression. `where r.active` keeps the rows whose `active` field is truthy.

#### Dynamic semantics

Evaluating a query expression evaluates the sources left to right, then the bound parameters and host closures in clause parse order, and builds a value of type `query` that holds them together with the plan. The query is lazy and does nothing further until run by the `query` iterator. Execution semantics (the fixed pipeline, provider push-down, nil and NaN ordering, aggregate rules) are a library concern documented in `guide.mdx` and tested in `query_test.lus`.

**Tested** (`query_test.lus`): clause words work as ordinary locals, fields, and methods outside queries. `@` inside comments and strings is inert. Queries appear in every expression position. A query ends at the first unrelated name. Clause order is free. `return @` and `return @t as` (truncated) fail with `<name> expected near <eof>`. Each pair of query values built separately is distinct. A query is not closable, cannot cross a worker boundary, and survives `string.dump`.

### 5.13 `continue`

**Source:** `syntax/parser.zig`, `compile/codegen.zig` (`patchContinues`). **Manual:** `guide.mdx`.

#### Syntax

```ebnf
stat = 'continue' ;
```

`continue` is an ordinary statement. It may appear anywhere in a block, and statements may follow it.

#### Static semantics

- `continue` belongs to the innermost enclosing loop of the current function: a numeric `for`, a generic `for`, a `while`, or a `repeat`. A loop outside an enclosing do-expression counts, so `continue` inside a do-expression inside a loop is valid.
- Outside every loop of the current function, including inside a function literal nested in a loop, it raises `continue outside loop`.
- In a `repeat` loop the `until` condition can read the locals of the body. A `continue` that would skip the declaration of a local that the condition can see raises `<continue> at line N jumps into the scope of 'x'`. Declaring the local before the `continue` is valid.
- `continue` is a reserved word, so it cannot name a variable or a label.

#### Dynamic semantics

`continue` closes the upvalues and to-be-closed variables of the blocks it leaves, then starts the next iteration. In a `for` loop it advances to the next value. In a `while` loop it evaluates the condition again. In a `repeat` loop it evaluates the `until` condition, which decides whether the loop runs again.

```lus
local odd = 0

for i = 1, 10 do
    if i % 2 == 0 then
        continue
    end

    odd = odd + i
end  -- odd == 25
```

---

### 5.14 `<meta>` locals

**Source:** `compile/codegen.zig` (`metaLocal`, `metaEval`, `isKnown`, `foldKnown`), `compile/meta.zig` (the meta state), `compile/dump.zig` (table and vector constants). **Design:** `spec/design/meta.md`. **Manual:** `guide.mdx`. **Tests:** `meta_test.lus`, `flags_test.lus`.

`local NAME <meta> = exp` evaluates `exp` at compile time in a fresh state with the standard library and the flags of the compilation, and binds `NAME` to the value as a constant. The rules are in `spec/design/meta.md`. The compile errors are:

- `a <meta> declaration names one variable` for a list of names,
- `a <meta> variable needs one initializer` without exactly one initializer,
- `cannot combine <meta> with <close>`, `with <group>`, `with <lazy>`, or `with runtime attributes`,
- `global variables cannot be <meta>` in a global declaration,
- `attempt to assign to const variable 'NAME'` for an assignment,
- `meta: 'x' is not known at compile time` for a local of the enclosing code that has no compile-time value,
- `meta value is a TYPE` and `meta value contains a TYPE at PATH` for a value that is not data,
- `meta: MESSAGE` with the position of the failing line for an error the initializer raises.

**Tested** (`meta_test.lus`): lookup tables, scalar constants, later initializers reading earlier ones, nested functions, read-only tables and vectors, one table per declaration, sharing and cycles, `string.dump`, the const rule, the rejected combinations, unknown locals, non-data values, error positions, no permissions without grants, the fresh environment, the fixed random seed, initializers in discarded branches, folded conditions with calls, and discarded `continue` and `provide`. **Tested** (`flags_test.lus`): pure calls on flags fold, other calls do not, and meta locals read flags.

### 5.15 `<lazy>` locals

**Source:** `compile/codegen.zig` (`lazyLocal`, `lazyRead`), `lib/lazy.zig` (the builtins), `compile/dump.zig` (builtin constants). **Design:** `spec/design/lazy.md`. **Manual:** `guide.mdx`. **Tests:** `lazy_test.lus`.

`local NAME <lazy> = exp` and a group field `NAME <lazy> = exp` evaluate `exp` on the first read of `NAME` and keep the value. `exp` sees variables as a function written at the declaration sees them. The rules are in `spec/design/lazy.md`. The compile errors are:

- `a <lazy> declaration names one variable` and `a <lazy> variable needs one initializer`,
- `cannot combine <lazy> with <group>` and `cannot combine <lazy> fields with runtime attributes of the group`,
- `cannot use <lazy> in this declaration` in `from` destructuring and assignment conditions, and `global variables cannot be <lazy>`,
- `attempt to assign to const variable 'NAME'` for an assignment, in any function.

The runtime errors are `lazy variable 'NAME' read during its own initialization` and `lazy variable 'NAME' read while another coroutine computes it`. An error that `exp` raises propagates from the read unchanged, and the next read evaluates `exp` again.

**Tested** (`lazy_test.lus`): one evaluation on the first read, no evaluation without a read, values at the first read, sharing with nested functions, the const rule, retry after an error, error objects passed unchanged, recursion, `nil` and `false` values, `<close>` only after a read, runtime attributes, group fields, the rejected forms, detached coroutines that wait, plain coroutines that raise, `string.dump`, and hot loop reads.

### 5.16 `<observe>` locals

**Source:** `compile/codegen.zig` (`observeLocal`, `assignStat`, `observeCheck`, `observeNotify`), `lib/lazy.zig` (the builtins and the update function). **Design:** `spec/design/observe.md`. **Manual:** `guide.mdx`. **Tests:** `observe_test.lus`.

`local NAME <observe> = exp` declares an observed local. If `exp` names another observed local, `NAME` is derived: an assignment to any observed local it depends on, directly or through other derived locals, evaluates `exp` again. Each dependent is computed once per assignment, in declaration order. The rules are in `spec/design/observe.md`. The compile errors are:

- `an <observe> declaration names one variable` and `an <observe> variable needs one initializer`,
- `cannot combine <observe> with <const>`, `with <close>`, `with <group>`, `with runtime attributes`, and `cannot combine <lazy> with <observe>` or `<meta> with <observe>`,
- `cannot use <observe> in this declaration` for a group field, `from` destructuring, or an assignment condition, and `global variables cannot be <observe>`,
- `attempt to assign to const variable 'NAME'` for an assignment to a derived local,
- `cannot assign observed variable 'NAME' with 'from'` and `with a function statement`.

The runtime error `cannot assign observed variable 'NAME' while its dependents update` comes from an assignment during an update, which includes an update paused by a yield. An error that an initializer raises during an update propagates from the assignment that started it.

**Tested** (`observe_test.lus`): the motivating example, a diamond computed once in order, transitive chains, assignments from nested functions, a writer declared before its dependent, the end of a dependent's scope, multiple assignment, the const rule, the rejected forms, an error during an update, an assignment during an update, a yield during an update, closing a paused update, and `string.dump`.

### 5.17 `<context>` locals

**Source:** `compile/codegen.zig` (`contextLocal`, `contextRead`, `contextStore`), `vm/context.zig` (slots and arrays), `lib/context.zig` (slot objects, the `ctxnew` builtin, `debug.getcontext` and `debug.setcontext`). **Design:** `spec/design/context.md`. **Manual:** `guide.mdx`. **Tests:** `context_test.lus`.

`local NAME <context> = exp` declares a context local, whose value belongs to the running coroutine. `exp` is evaluated once, when the declaration runs, and is the default. Each run of the declaration creates a new variable. A hidden local holds the slot object of the variable, so closures capture it like any local. A read compiles to `GETCTX` and an assignment to `SETCTX`. A new coroutine starts with the values of the coroutine that creates it. The compile errors are:

- `a <context> declaration names one variable` and `a <context> variable takes one initializer`,
- `cannot combine <context> with <const>`, `with <close>`, `with <group>`, `with <meta>`, `with <lazy>`, `with <observe>`, and `with runtime attributes`,
- `cannot use <context> in this declaration` for a group field, `from` destructuring, or an assignment condition, and `global variables cannot be <context>`.

A slot object that `debug.setlocal` replaced with another value raises `the slot of a context variable was replaced` at the next read or write.

**Tested** (`context_test.lus`): the default, a declaration without initializer, an assignment that stays in its coroutine, inheritance at creation by plain and detached coroutines, `nil` as a value, closures, a new variable per run, two variables of one name, `debug.getcontext` and `debug.setcontext`, reclaimed slots, and the rejected forms.

## 6. Compile-time error catalog

### 6.1 Message format

A chunk that fails to compile produces a single string message. `load` returns `nil` and the message.

- **Syntax errors** have the form `CHUNK:LINE: MESSAGE near TOKEN`, where `LINE` is the line of the current token and `TOKEN` is the current token. Fixed tokens and keywords appear in single quotes (`'end'`, `'='`). Names, strings, and numerals appear as their source text in single quotes (`'foo'`). End of input appears as `<eof>`. Interpolation tokens appear as `<interp_begin>`, `<interp_mid>`, `<interp_end>`, or `<interp_simple>`.
- **Semantic errors** have the form `CHUNK:LINE: MESSAGE` with no `near` part, where `LINE` is the line of the construct.
- **Unclosed blocks** produce `'X' expected near TOKEN` when the opener is on the current line and `'X' expected (to close 'Y' at line N) near TOKEN` otherwise.
- **Limits** produce `too many WHAT (limit is N) in main function` or `... in function at line N`.
- **Chunk names**: a name beginning with `=` or `@` is shown without that prefix. Any other name is shown as `[string "..."]`, cut at the first line break or after 45 bytes and then followed by `...`.
- Recursion in the parser is bounded at 200 nested levels of statements and expressions. Exceeding it raises `chunk has too many syntax levels (stack overflow)`. Blocks nest 200 deep, table constructors 199, and parentheses 198. A function literal takes two levels, so functions nest at most 99 deep.

### 6.2 Messages of the constructs of section 5

| Message | Kind | Raised by |
| --- | --- | --- |
| `unfinished interpolated string` | lexical | `syntax/lexer.zig` |
| `invalid interpolation after '$'` | lexical | `syntax/lexer.zig` |
| `invalid escape sequence in interpolated string` | lexical | `syntax/lexer.zig` |
| `invalid UTF-8 in string literal (use a vector for raw bytes)` | semantic | `compile/codegen.zig` |
| `'provide' outside do expression` | syntax | `syntax/parser.zig` |
| `continue outside loop` | semantic | `compile/codegen.zig` |
| `<continue> at line N jumps into the scope of 'X'` | semantic | `compile/codegen.zig` |
| `too many names in enum` | syntax | `syntax/parser.zig` |
| `duplicate enum member 'X'` | semantic | `syntax/parser.zig` |
| `'from' requires simple variable names` | semantic | `compile/codegen.zig` |
| `cannot use 'from' with to-be-closed variables` | semantic | `compile/codegen.zig` |
| `cannot use 'from' with <group> variables` | semantic | `compile/codegen.zig` |
| `runtime attributes not supported with 'from'` | semantic | `compile/codegen.zig` |
| `runtime attributes not supported with multiple variables` | semantic | `compile/codegen.zig` |
| `runtime attributes not supported in this context` | semantic | `compile/codegen.zig` |
| `compile-time attribute 'X' must come before runtime attributes` | semantic | `syntax/parser.zig` |
| `conflicting attributes` | semantic | `syntax/parser.zig` |
| `multiple to-be-closed variables in condition` | semantic | `compile/codegen.zig` |
| `cannot mix <group> with non-group variables` | semantic | `compile/codegen.zig` |
| `cannot mix <group> with non-group variables in condition` | semantic | `compile/codegen.zig` |
| `cannot use <close> with <group> variables` | semantic | `compile/codegen.zig` |
| `group can only be copied from another group` | semantic | `compile/codegen.zig` |
| `group can only be assigned a constructor or another group` | semantic | `compile/codegen.zig` |
| `cannot pass local group` | semantic | `compile/codegen.zig` |
| `'X' is not a field of group 'G'` | semantic | `compile/codegen.zig` |
| `cannot deconstruct subgroup 'X' with 'from'` | semantic | `compile/codegen.zig` |
| `cannot overwrite subgroups` | semantic | `compile/codegen.zig` |
| `expected ',' or ';' in group constructor` | semantic | `syntax/parser.zig` |
| `global variables cannot be groups` | semantic | `compile/codegen.zig` |
| `cannot declare 'flags' (reserved name)` | semantic | `compile/codegen.zig` |
| `nested queries are not supported` | semantic | `syntax/parser.zig` |
| `too many sources in query` | semantic | `syntax/parser.zig` |
| `query source index must be a literal` | semantic | `syntax/parser.zig` |
| `query source needs an 'as' name` | semantic | `syntax/parser.zig` |
| `duplicate row variable 'X' in query` | semantic | `syntax/parser.zig` |
| `duplicate 'CLAUSE' clause in query` | semantic | `syntax/parser.zig` |
| `'by' expected after 'group'`, `'by' expected after 'order'` | semantic | `syntax/parser.zig` |
| `'as' name expected for this projection` | semantic | `syntax/parser.zig`, `compile/query_gen.zig` |
| `a join requires a 'select' clause` | semantic | `syntax/parser.zig` |
| `query limit must be row-independent`, `query offset must be row-independent` | semantic | `compile/query_gen.zig` |
| `aggregate 'X' is only allowed in 'select' or 'having'` | semantic | `compile/query_gen.zig` |
| `aggregates cannot nest` | semantic | `compile/query_gen.zig` |
| `'*' is only allowed in count` | semantic | `syntax/parser.zig` |
| `operator not supported in a query clause` | semantic | `syntax/parser.zig`, `compile/query_gen.zig` |
| `a suffix on a parenthesized expression is not supported in a query clause` | semantic | `syntax/parser.zig` |
| `query too complex` | semantic | `syntax/parser.zig`, and `vm/query.zig` when the query value is built |

### 6.3 Messages inherited from Lua 5.5

`unexpected symbol`, `syntax error`, `'X' expected`, `'X' expected (to close 'Y' at line N)`, `<name> expected`, `<name> or '...' expected`, `<eof> expected`, `function arguments expected`, `'=', 'in' or 'from' expected`, `break outside loop`, `cannot use '...' outside a vararg function`, `attempt to assign to const variable 'X'`, `variable 'X' not declared`, `_ENV is global when accessing variable 'X'`, `global variables cannot be to-be-closed`, `multiple to-be-closed variables in local list`, `label 'X' already defined on line N`, `no visible label 'X' for <goto> at line N`, `<goto X> at line N jumps into the scope of 'Y'`, `control structure too long`, `too many constants`, and the limit messages for `local variables`, `upvalues`, and `registers`.

### 6.4 Runtime errors of the constructs of section 5

| Message | Construct |
| --- | --- |
| `attempt to use a TYPE value as a catch handler` | `catch[h]` with a non-function handler |
| `slice index must be an integer` | slice bound of the wrong type |
| `slice span too large` | table slice over 2^26 elements |
| `attempt to slice a TYPE value` | slice of a value without slice support |
| `'__tostring' must return a string` | interpolation of a value whose `__tostring` returns neither a string nor a number |
| `global 'X' already defined` | initializing `global` declaration or `global function` |
| `attempt to compare members of different enums` | ordering comparison across two enums |
| `corrupt query plan in bytecode` | a query plan in a loaded binary chunk that fails validation |

---

## 7. Edge cases at a glance

### 7.1 Behavior worth remembering

1. `if a <b then` is an attribute list, `if a < b then` is a comparison (section 2.1).
2. `local x <const>= 1` fails because `>=` is one token.
3. `do` at statement start is always a block. `while x = do end` consumes `do` as a do-expression.
4. `catch` extends rightward over a full expression. In single-value position it yields only its status.
5. Optional chains are rvalues. A chain that ends in a call cannot be a statement. Calls in a chain yield exactly one value. Short-circuit returns the falsy value itself.
6. Slices clamp for strings and vectors, never for tables, and reverse when start > end. Strings slice by character. Numeric strings are accepted as bounds.
7. `$name` takes only identifier characters, and a reserved word after `$` is an error.
8. An `enum` expression is a constant of its function: re-evaluation yields the same enum.
9. `from` reads fields left to right through `__index` and stores right to left.
10. `while` assignment variables are one shared binding across iterations.
11. `provide` may jump out of loops and nested blocks. `break`, `continue`, `goto`, and `return` may leave a do-expression. `provide` takes no trailing `;`.
12. Runtime attribute handlers are skipped for `nil`, ignore `nil` results, and do not run for upvalue writes, group overwrites, or subgroup fields.
13. Group copies share subgroups with their source. Group field locals are reachable only through group paths.
14. Folding only touches `if`/`elseif` with the four exact shapes and never runs when an AST is built.
15. A query ends at the first token that is not a clause keyword. `order by name` with a non-row name is an alias reference. Aggregate names followed by `(` are always aggregates inside clauses.
16. `global *` anywhere in scope re-enables free names below later named declarations.
17. Every string literal is well formed WTF-8. Raw bytes belong in vectors.
18. `continue` in a `repeat` loop may not skip a local that the `until` condition can see.

### 7.2 Manual statements checked against the implementation

The manual pages agree with the implementation on every point this reference covers. The table lists three statements that readers often check against the grammar, with the section that specifies each one and names its tests.

| Manual | Statement | Section |
| --- | --- | --- |
| `guide.mdx` | an optional chain is an expression, so a call kept for its effect is written `local _ = obj?:process()` | 5.2 |
| `guide.mdx` | runtime attributes follow the variable name | 5.9 |
| `guide.mdx` | a bare column filters by truthiness | 5.12 |

---

## 8. Source map

All paths are relative to `runtime/src/`.

| Topic | Locations |
| --- | --- |
| tokens, keywords | `syntax/token.zig` |
| lexing (numerals, strings, long brackets, interpolation) | `syntax/lexer.zig` |
| statements, expressions, attributes, queries | `syntax/parser.zig`, `syntax/ast.zig` |
| name resolution, locals, globals, groups, flags folding | `compile/codegen.zig` |
| query plans | `compile/query_gen.zig`, `vm/query.zig` |
| catch, slices, enums, interpolation conversion | `vm/interp.zig`, `vm/ext.zig`, `vm/ops.zig` |
| error formatting | `syntax/parser.zig` (`errNear`, `errSem`, `chunkDisplay`), `compile/codegen.zig` (`Compiler.err`) |

The grammar descends from the Lus 1.7 C implementation. Its lexer and parser are `lus/src/llex.c` and `lus/src/lparser.c` at the `v1.7-legacy` tag.
