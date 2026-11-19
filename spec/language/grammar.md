# Lus language grammar and semantics

This document is the reference for the Lus surface language as the legacy 1.7 C implementation accepts it. It covers the lexical grammar, the full syntactic grammar in EBNF, operator precedence, and the static and dynamic semantics of every construct Lus adds on top of Lua 5.5. It is written for the implementer of the Zig lexer, parser, and compiler, and it is meant to replace reading `llex.c`, `lparser.c`, `lcode.c`, and the relevant parts of `lvm.c`.

The base language is Lua 5.5 (the fork point is Lua 5.5 RC 2). Where Lus behaves exactly like Lua 5.5, this document states the rule briefly and moves on. Where Lus adds or changes behavior, the rule is spelled out in full.

Three kinds of annotation appear throughout.

- **Source** lines cite the legacy implementation as `file:function`. All files live under `legacy/lus/src/`.
- **Pinned** notes record behavior that a test under `legacy/lus-tests/h1/` asserts. The rewrite must reproduce these.
- **Legacy defect** notes record behavior that the legacy implementation exhibits but that is clearly unintended (a crash, a contradiction with the manual, or a scoping leak). Each one carries a recommendation for the rewrite. These notes were verified by running the legacy binary (`legacy/lus/build/lus`).

## Contents

1. Lexical grammar
2. Syntactic grammar
3. Operator precedence
4. Base language semantics
5. Lus extensions
6. Compile-time error catalog
7. Edge cases and legacy defects at a glance
8. Source map

## Notation

The EBNF uses the following conventions. `{ x }` means zero or more repetitions of `x`. `[ x ]` means `x` is optional. `( a | b )` groups alternatives. Quoted text such as `'end'` or `'?'` is a literal token. Capitalized names such as `Name`, `Numeral`, and `LiteralString` are token classes from the lexer. Lowercase names are nonterminals. A rule written as `x(limit)` takes a precedence limit parameter, as described in section 3.

Error messages are quoted exactly as the legacy implementation produces them. Messages from `luaX_syntaxerror` carry a trailing ` near TOKEN` part. Messages from `luaK_semerror` carry no `near` part. Section 6 explains the full message format.

---

## 1. Lexical grammar

**Source:** `llex.c` (all functions), `llex.h:enum RESERVED`.

### 1.1 Source text and line structure

A chunk is a sequence of bytes. The lexer treats it as 8-bit text with no encoding. Identifier characters are ASCII only: letters `A-Z` and `a-z`, digits `0-9`, and the underscore. Bytes at or above 0x80 are not identifier characters.

A line break is any of `\n`, `\r`, `\r\n`, or `\n\r`. Each of these sequences counts as exactly one line and advances the line counter by one. Exceeding `INT_MAX` lines raises `chunk has too many lines`. The lexer also tracks a 1-based column, reset to 1 after each line break, which only the AST and diagnostics use.

Whitespace between tokens is space, `\t`, `\v`, `\f`, and line breaks.

A first line that starts with `#` is skipped by the file loader (`luaL_loadfilex`), which enables shebang lines. This happens outside the lexer, so `load("#!x\nreturn 1")` sees the `#` as a token.

**Pinned** (`lexer-errors.lus`): LF, CRLF, and bare CR all advance the line count identically, so an error on the third line is reported at line 3 for every terminator style.

### 1.2 Comments

A comment starts with `--` anywhere outside a string.

- If `--` is immediately followed by a long bracket opener (`[`, zero or more `=`, `[`), the comment is a long comment that ends at the matching closer of the same level. Its content is discarded.
- Otherwise the comment runs to the end of the line. This includes `--[` followed by something other than a valid opener, such as `--[==x`, which is a short comment.

An unterminated long comment raises `unfinished long comment (starting at line N) near <eof>`.

### 1.3 Names and keywords

```ebnf
Name = ( letter | '_' ) { letter | digit | '_' } ;   (* not a reserved word *)
```

The reserved words are exactly the entries of `luaX_tokens`, in this order:

```
and       break     catch     do        else      elseif    end
enum      false     for       from      function  global    goto
if        in        local     nil       not       or        provide
repeat    return    then      true      until     while
```

Compared to Lua 5.5, Lus adds `catch`, `enum`, `from`, and `provide`. The word `global` is always reserved (the build leaves `LUA_COMPAT_GLOBAL` undefined). None of the reserved words can be used as a variable name, a field name after `.` or `:`, or an enum member.

**Pinned** (`compile-errors.lus`): `local from = 1`, `local provide = 1`, `local enum = 1`, `local global = 1`, and `local catch = 1` all fail with `<name> expected near 'KEYWORD'`.

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

The Lus-specific tokens are `?` (optional chaining) and `@` (query). Each is an ordinary single-character token, and `?` and the suffix after it are separate tokens. Whitespace and comments may therefore appear between them. For example `t ? .a` is valid and means `t?.a`.

The backtick `` ` `` starts an interpolated string (section 1.8). The `$` byte has meaning only inside an interpolated string. Elsewhere it lexes as a single-character token that no grammar rule accepts, so it produces `unexpected symbol near '$'`.

Lexing is greedy. Two consequences matter for Lus syntax.

- `<const>=` lexes as `<`, `const`, `>=`, so `local x <const>= 1` fails with `'>' expected near '>='`. A space is required before `=` after an attribute list.
- `a?.b` lexes as `a`, `?`, `.`, `b`. A numeral such as `?.5` is never formed because `?` is consumed first.

### 1.5 Numerals

**Source:** `llex.c:read_numeral`, `lobject.c:luaO_str2num`.

The lexer collects a numeral liberally and then validates it with `luaO_str2num`. The collection pattern is:

```
decimal:  digit { hexdigit | '.' | ( 'E' | 'e' ) [ '+' | '-' ] }
hex:      '0' ( 'x' | 'X' ) { hexdigit | '.' | ( 'P' | 'p' ) [ '+' | '-' ] }
```

A numeral may also start with `.` when the `.` is directly followed by a digit (`.5`). A sign is accepted only immediately after an exponent mark, so `3-4` is three tokens and `0xe+1` is `0xe`, `+`, `1`. If the collected text is directly followed by a letter or underscore, that character is appended to force a validation failure.

The accepted forms after validation are:

| Form | Examples | Value |
| --- | --- | --- |
| decimal integer | `0`, `42` | integer. If it overflows 64 bits it becomes a float (`9223372036854775808` reads as `9.2233720368547758e+18`) |
| decimal float | `3.`, `.5`, `1e3`, `1.5e-2` | float |
| hex integer | `0xFF`, `0xffffffffffffffff` | integer, wrapping modulo 2^64 (`0xffffffffffffffff` is `-1`) |
| hex float | `0x1p4`, `0x1.8p1`, `0x.8p1`, `0x1.p3`, `0xA.8p0` | float with a binary exponent |

Any other collected text raises `malformed number near 'TEXT'`. **Pinned** (`lexer-errors.lus`): `0x`, `0X`, `1e`, `1e+`, `1e-`, `1.2.3`, `0x1p`, `0x1p+`, `0x.p2`, `3xyz`, and `0b101` are malformed. `0x1p3`, `0x1.8p1`, `0x1.p3`, `0x.8p1`, `1e3`, `1.5e-2`, `.5`, and `0xABCp0` are valid. `1..2` is also malformed because the collector swallows both dots.

### 1.6 Short strings

**Source:** `llex.c:read_string`.

A short string is delimited by `"` or `'` and may not contain an unescaped line break. The escape sequences are:

| Escape | Meaning |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | the usual control bytes |
| `\\` `\"` `\'` | the literal byte |
| `\` followed by a line break | a single `\n` byte (a two-byte break sequence counts once) |
| `\xXX` | exactly two hex digits, one byte |
| `\ddd` | one to three decimal digits, value at most 255. Reading stops after three digits, so `"\65B"` is `"AB"` |
| `\u{X...}` | one or more hex digits, value at most `0x7FFFFFFF`, encoded as extended UTF-8 of up to six bytes |
| `\z` | skips the following run of whitespace, including line breaks |

Error messages (each ends with `near` followed by the partial string text including the offending escape):

| Message | Cause |
| --- | --- |
| `unfinished string` | a raw line break inside the string. The `near` text is the partial string, such as `'"bad'` |
| `unfinished string near <eof>` | end of input inside the string |
| `invalid escape sequence` | `\` followed by any byte not listed above |
| `hexadecimal digit expected` | `\x` without two hex digits, or `\u{` without a first hex digit |
| `decimal escape too large` | `\ddd` above 255 |
| `missing '{'` | `\u` not followed by `{` |
| `missing '}'` | `\u{...` not closed by `}` right after the digits |
| `UTF-8 value too large` | `\u{...}` above `0x7FFFFFFF` |

**Pinned** (`lexer-errors.lus`): `\u{110000}` and `\u{7FFFFFFF}` are accepted. `\u{80000000}` is rejected. An embedded `\0` is a real byte.

### 1.7 Long brackets

**Source:** `llex.c:skip_sep`, `llex.c:read_long_string`.

A long bracket opener is `[`, then `n` equals signs (n >= 0), then `[`. Its closer is `]`, the same `n` equals signs, then `]`. A long string runs from the opener to the first closer of the same level. Closers of other levels are content. A line break immediately after the opener is dropped. Every line break sequence inside is stored as a single `\n`. No escapes are processed.

Error messages:

- `unfinished long string (starting at line N) near <eof>`, where N is the line of the opener.
- `invalid long string delimiter near 'TEXT'` when `[` followed by one or more `=` is not followed by a second `[`. A lone `[` with no `=` is the index token.

### 1.8 Interpolated strings

**Source:** `llex.c:read_interp_section`, `llex.c:llex` (cases `` ` ``, `(`, `)`), `llex.h` (`TK_INTERP_*`), `lparser.c:interpexp`.

An interpolated string is delimited by backticks. It may span lines. It contains literal text, `$name` references, and `$(expr)` expressions.

#### 1.8.1 Token stream

The lexer splits an interpolated string into four token kinds. Each carries the literal text of its section (possibly empty) as its semantic value.

| Token | Display name | Lexed at | Means |
| --- | --- | --- | --- |
| `TK_INTERP_SIMPLE` | `<interp_simple>` | opening backtick | the whole string, which has no interpolation |
| `TK_INTERP_BEGIN` | `<interp_begin>` | opening backtick | literal prefix, then an interpolation follows |
| `TK_INTERP_MID` | `<interp_mid>` | end of an interpolation | literal text, then another interpolation follows |
| `TK_INTERP_END` | `<interp_end>` | end of an interpolation | final literal text, then the closing backtick |

Lexing proceeds as follows.

1. On `` ` ``, the lexer reads a section (step 3) with the begin kind `TK_INTERP_BEGIN` and the end kind `TK_INTERP_SIMPLE`.
2. When an interpolation finishes, the lexer reads the next section with the begin kind `TK_INTERP_MID` and the end kind `TK_INTERP_END`.
3. Reading a section accumulates literal bytes until one of these occurs:
   - `` ` `` ends the string and returns the end kind.
   - `$$` appends a literal `$`.
   - `$(` returns the begin kind and enters expression mode with a parenthesis depth of 1.
   - `$` followed by a letter or underscore reads a name `[A-Za-z_][A-Za-z0-9_]*` greedily, returns the begin kind with that name attached as the interpolated variable, and arranges for the very next token request to read the following section (step 2) immediately.
   - `$` followed by anything else raises `invalid interpolation after '$'`.
   - A raw line break appends a single `\n`.
   - End of input raises `unfinished interpolated string near <eof>`.
4. In expression mode, the lexer produces ordinary tokens. Each `(` increments the depth and each `)` decrements it. The `)` that brings the depth to 0 closes the interpolation. The lexer consumes it, reads the next section (step 2), and returns that section's `TK_INTERP_MID` or `TK_INTERP_END` token in the position of the `)`. Parentheses inside string literals and comments within the expression are part of those tokens and do not affect the depth.

The escapes inside interpolated sections are a separate, smaller set:

| Escape | Meaning |
| --- | --- |
| `` \` `` | literal backtick |
| `\$` | literal `$` |
| `\n` `\t` `\r` | newline, tab, carriage return |
| `\\` | literal backslash |
| `\` followed by a line break | a single `\n` |

Any other escape raises `invalid escape sequence in interpolated string`. Quotes need no escaping inside backticks (`` `a'b"c` `` is `a'b"c`). The escapes `\x`, `\u`, `\z`, `\ddd`, `\a`, `\b`, `\f`, `\v`, `\"`, and `\'` are all errors inside backticks.

#### 1.8.2 Parsing

```ebnf
interpstring = InterpSimple
             | InterpBegin interppart { InterpMid interppart } InterpEnd ;
interppart   = (* the name attached to the preceding token *)
             | expr ;    (* when the preceding token came from '$(' *)
```

For a `$name` interpolation the parser does not see the name as a token. The name rides on the `TK_INTERP_BEGIN` or `TK_INTERP_MID` token, and the parser resolves it as a variable reference (section 5.4).

For a `$(expr)` interpolation the parser consumes the begin or mid token, parses one `expr`, and then expects the lexer to deliver the next `TK_INTERP_MID` or `TK_INTERP_END`.

**Legacy defect.** After `$(expr)`, the legacy parser does not check that the current token is `TK_INTERP_MID` or `TK_INTERP_END`. If the expression ends early, as in `` `$( {1}[1] )` `` where the constructor cannot take a suffix, the parser reads a stale semantic value and the process crashes with a segmentation fault. The rewrite must check the token and raise a syntax error (for example `')' expected near '['`).

**Legacy defect.** The lexer keeps a single depth counter and a single pending-name flag. An interpolated string nested inside `$(...)` works only when the inner string has no interpolation of its own. **Pinned** (`compile-errors.lus`): `` `o $( `i` ) o` `` evaluates to `"o i o"`. An inner string with its own `$(...)` or `$name`, such as `` `a $( `b $(1) c` ) d` ``, corrupts the outer state and fails to compile with an unrelated message. The rewrite should lex interpolated strings with a mode stack so that nesting works to any depth, while keeping the single-level behavior identical.

**Pinned** (`compile-errors.lus`):

| Source | Result |
| --- | --- |
| `` local s = `abc `` | `unfinished interpolated string near <eof>` |
| `` local s = `abc $( `` | `unexpected symbol near <eof>` |
| `` local s = `abc $( 1 + 2` `` | `unfinished interpolated string near <eof>` (the backtick opens a nested string) |
| `` return `x $()` `` | `unexpected symbol near <interp_end>` |
| `` return `100$` ``, `` return `a $ b` ``, `` return `$1` `` | `invalid interpolation after '$'` |
| `` return `$$` `` | `"$"` |

### 1.9 Lexical error format

A lexical error message has the form `CHUNK:LINE: MESSAGE near TOKEN`, where `LINE` is the line at which the lexer currently is. For errors raised with a token of `<eof>`, the `near` part is `near <eof>`. For number and string errors, `TOKEN` is the raw text collected so far in single quotes. `lexical element too long` (a token near `MAX_SIZE`) carries no `near` part.

---

## 2. Syntactic grammar

**Source:** `lparser.c` (the functions named in each rule's comment).

This grammar describes what the legacy parser accepts. Semantic restrictions that the parser enforces after syntax (for example that only variables may be assigned) are given in sections 4 and 5. The start symbol is `chunk`.

```ebnf
(* ---------- chunks and blocks ---------- *)

chunk      = block ;                                     (* mainfunc *)

block      = { stat } [ laststat ] ;                     (* statlist *)

laststat   = retstat
           | providestat ;    (* only inside a do-expression, section 5.8 *)

retstat    = 'return' [ explist ] [ ';' ] ;              (* retstat *)
providestat = 'provide' [ explist ] ;                    (* providestat, no ';' *)

(* ---------- statements ---------- *)

stat = ';'
     | label
     | 'break'
     | 'goto' Name
     | 'do' block 'end'
     | 'while' cond 'do' block 'end'
     | 'repeat' block 'until' expr
     | 'if' cond 'then' block { 'elseif' cond 'then' block } [ 'else' block ] 'end'
     | 'for' Name '=' expr ',' expr [ ',' expr ] 'do' block 'end'
     | 'for' Name { ',' Name } 'in' explist 'do' block 'end'
     | 'function' funcname funcbody
     | 'local' 'function' Name funcbody
     | 'local' localdecl
     | 'global' 'function' Name funcbody
     | 'global' globaldecl
     | catchstat
     | exprstat ;

label      = '::' Name '::' ;

catchstat  = 'catch' [ '[' expr ']' ] expr ;             (* catchstat *)

funcname   = Name { '.' Name } [ ':' Name ] ;

(* ---------- local declarations ---------- *)

localdecl  = attnamelist [ '=' explist | 'from' fromsource ]
           | groupnamelist '=' groupinit { ',' groupinit } ;

attnamelist   = Name [ attribs ] { ',' Name [ attribs ] } ;
groupnamelist = attnamelist ;   (* every name carries the 'group' attribute *)

attribs    = '<' attrib { ',' attrib } '>' ;             (* parseattributes *)
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

cond       = assigncond | expr ;                         (* test_then_block, whilestat *)

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

catchexp   = 'catch' [ '[' expr ']' ] expr ;             (* catchexpr *)
doexp      = 'do' block 'end' ;                          (* doexpr *)
enumexp    = 'enum' Name { ',' Name } 'end' ;            (* enumexpr *)

suffixedexp = primaryexp { suffix } ;                    (* suffixedexp, suffixchain *)
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

queryexp   = '@' qsource { ',' qsource } { qclause } ;   (* queryexpr *)

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

The grammar above is ambiguous in a few places. The legacy parser resolves each ambiguity with the following rules, which the rewrite must reproduce.

**Statement start.** A statement is dispatched on its first token. `if`, `while`, `do`, `for`, `repeat`, `function`, `local`, `global`, `::`, `return`, `provide`, `break`, `catch`, and `goto` each select their own rule. Every other token starts an `exprstat`. Consequently:

- `do` at statement start is always a block statement, never a do-expression. A do-expression can appear only where an expression is expected.
- `catch` at statement start is always a catch statement.
- `enum` and `@` at statement start fail with `unexpected symbol near 'enum'` or `unexpected symbol near '@'`, because `exprstat` begins with `primaryexp`.
- `from` at statement start fails with `unexpected symbol near 'from'`.

**Expression statements.** An `exprstat` begins by parsing one `suffixedexp`. If the next token is `=`, `,`, or `from`, the statement is an assignment. Otherwise the expression must be a plain function call (`VCALL`), or the parser raises `syntax error` near the following token.

**Assignment condition detection** (`lparser.c:isassigncond`). After `if`, `elseif`, or `while`, the condition is an `assigncond` exactly when the current token is a `Name` and one of the following holds.

- The next token is `=`, `,`, or `from`.
- The next token is `<` and the very next source byte after `<` is a letter or underscore.

This is a lexer-level peek, so whitespace matters. **Legacy behavior** (verified): `if a <b then` is read as an attribute list and fails with `'>' expected near 'then'`, while `if a < b then` is a comparison. The rewrite must keep this rule exactly.

`repeat ... until` takes a plain `expr`. It never accepts an assignment condition.

**Table field versus expression.** Inside a table constructor, a `Name` followed by `=` is a record field. A `Name` followed by anything else starts a list item expression. This uses one token of lookahead.

**Group paths.** When `primaryexp` resolves to a local group variable, the parser enters group mode before the suffix chain. In group mode the next token must be `.` followed by a field name, or `=` (for a group overwrite at statement level). Any other token raises `cannot pass local group`. Group mode continues through subgroup fields and ends at the first ordinary field, after which the regular suffix chain resumes. See section 5.10.

**Group sources after `from`.** If the token after `from` is a `Name` that resolves, in the current function, to a local group, only that `Name` token is consumed and the source is the group. Otherwise the source is a full `expr`.

**Attribute lists versus comparisons in declarations.** After the name in `local`, `global`, a group field, or an assignment condition, a `<` always opens an attribute list. A declaration takes at most one attribute list per name. A second list such as `local x <const> <const> = 1` fails with `unexpected symbol near '<'`.

**Attribute names.** Inside `< >`, an attribute whose first token is the name `const`, `close`, or `group` is the corresponding compile-time attribute and consists of that single token. Every other attribute is parsed as `subexpr(3)`, which accepts arithmetic, bitwise, concatenation, calls, indexing, function literals, and parenthesized expressions, and stops at any comparison operator, `and`, or `or`. **Pinned** (`runtime-attrs.lus`): `<handlers[1+2]>`, `<function(name, value) return value + 100 end>`, `<(use_doubler and double or triple)>`, `<(handlers.get())>`, `<attrs["my" .. "handler"]>`, and `<handlers[2 | 4]>` all parse.

**Optional chain extent.** A `?` is a suffix like any other. It may appear anywhere in the suffix chain, any number of times, including at the very end (`x = t?`).

**Slice versus index.** After `[`, a leading `,` or a `,` after the first expression makes the bracket a slice. A slice has at most two bound positions, so `t[1, 2, 3]` fails with `']' expected near ','`. Empty brackets `t[]` fail with `unexpected symbol near ']'`.

**Query extent.** A query extends through its sources and then through clauses for as long as the current token is a `Name` that spells a clause keyword. The first token that is not a clause keyword ends the query, whether it is a `Name` (`local q = @t as x where x.a > 1 local y = 2` ends the query at `local`, and a bare `print` would also end it) or any other token. Clause expressions extend as far as `qexpr` reaches.

**Atoms without suffixes.** `simpleexp` alternatives other than `suffixedexp` cannot take suffixes. This includes numerals, all string forms (interpolated strings included), constructors, function literals, `catch`, do-expressions, `enum`, and queries. Wrap such an expression in parentheses to index or call it, as in `("abc"):upper()` or `(enum a, b end).b`. Interpolated strings are not valid call arguments in the string-call form (`` f`x` `` is a syntax error), since `args` accepts only `LiteralString`.

**Last statements.** `return` and `provide` end their block. After either, the parser requires a block terminator (`end`, `else`, `elseif`, `until`, or end of input). `return` may be followed by one optional `;`. `provide` may not. **Legacy behavior** (verified): `local x = do provide 1; end` fails with `'end' expected near ';'`. The rewrite should keep this unless the language is deliberately changed to match `return`.

---

## 3. Operator precedence

**Source:** `lparser.c:priority`, `lparser.c:subexpr`, `lparser.c:UNARY_PRIORITY`.

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

## 4. Base language semantics

This section summarizes the Lua 5.5 rules that the Lus parser implements, with the Lus-specific details that touch them. It is not a full restatement of the Lua 5.5 manual.

### 4.1 Scoping and variables

**Source:** `lparser.c:searchvar`, `singlevaraux`, `buildvar`, `buildglobal`, `adjustlocalvars`.

Lus is lexically scoped. A local declared by `local` enters scope at the statement after its declaration. In `local x = x` the right-hand `x` refers to the outer binding. The variable of `local function f` enters scope before the body, so the function can call itself.

A name resolves by scanning active declarations of the current function from innermost to outermost, then the enclosing functions (creating upvalues), and finally as a global. Global declarations participate in the same scan (section 4.3).

Limits: at most 200 active locals per function (`too many local variables (limit is 200) in main function` or `... in function at line N`), at most 255 upvalues per function (`too many upvalues (limit is 255) in ...`), and at most 255 registers (`too many registers (limit is 255) in ...`). Hidden internal variables such as the three generic-for state slots, the do-expression anchor, and runtime attribute slots count toward the local limit.

### 4.2 Local attributes

**Source:** `lparser.c:localstat`, `parseattributes`, `checktoclose`, `lcode.c:luaK_exp2const`.

- `<const>` makes the variable read-only. Any assignment to it, from the same function or from a closure, raises `attempt to assign to const variable 'x'` at compile time. If the const variable is the last one in its list, the number of variables equals the number of expressions, it has no runtime attributes, and its initializer is a compile-time constant (`nil`, `true`, `false`, a string literal, a numeral, constant-folded arithmetic, or another compile-time constant), the variable becomes a compile-time constant that occupies no register. A const without an initializer is still read-only (`local x <const> x = 1` is an error).
- `<close>` marks the variable to be closed. At most one per declaration list (`multiple to-be-closed variables in local list`). When the variable goes out of scope, normally or through an error, its `__close` metamethod runs. A value that is neither `nil`, `false`, nor closable raises a runtime error naming the variable.
- `<group>` declares a local group (section 5.10).
- Combining two different compile-time attributes on one name raises `conflicting attributes`. Repeating the same one inside one list (`<const, const>`) is accepted.
- Any other attribute is a runtime attribute (section 5.9).

The control variable of a numeric `for` and the first variable of a generic `for` are read-only (`for i = 1, 3 do i = 5 end` raises `attempt to assign to const variable 'i'`). **Pinned** (`compile-errors.lus`).

### 4.3 Global declarations

**Source:** `lparser.c:globalstat`, `globalnames`, `globalfunc`, `initglobal`, `globalfrom`, `checkglobal`, `searchvar`, `buildvar`, `lcode.c:luaK_codecheckglobal`, `ldebug.c:luaG_errnnil`.

Lus follows the Lua 5.5 global declaration model.

- Every chunk begins with an implicit collective declaration. Until the first explicit `global` statement in scope, any free name is a global variable `_ENV.name`.
- `global name {, name}` declares those names for the rest of the enclosing block. `global *` declares all names collectively. An attribute list before the names or `*` sets the default kind for the whole statement, and an attribute list after a name sets the kind of that name.
- Allowed global attributes are `const` only. `close` raises `global variables cannot be to-be-closed`. `group` raises `global variables cannot be groups`. Any runtime attribute raises `runtime attributes not supported in this context`.
- Name resolution for a free name scans the active declarations from innermost to outermost (continuing into enclosing functions). A matching named declaration makes the name a declared global, read-only if it was declared `<const>`. If no named declaration matches, the innermost collective declaration in scope (if any) decides, and makes the name read-only if that collective declaration was `<const>`. If there is no collective declaration in scope and some named global declaration was passed during the scan, the parser raises `variable 'x' not declared`. If no global declaration of any kind was passed, the implicit declaration applies.
- A collective `global *` anywhere in scope therefore re-enables free names even below a later named declaration.
- The global name `_ENV` is itself resolved as a variable. If it resolves to a global, the parser raises `_ENV is global when accessing variable 'x'`.
- The name `flags` is exempt from all of this (section 5.11).

**Pinned** (`compile-errors.lus`, `global.lus`): reads and writes before the first `global` statement are unchecked. After it, any undeclared read or write is an error, including names that were written before the statement. Enforcement ends with the enclosing block. `global *` restores free names. `global 42` fails with `<name> expected near '42'`. `global x.y` fails with `unexpected symbol near '.'`.

Dynamic semantics of initialization:

- `global a, b = e1, e2` evaluates the expression list (adjusted to the number of names) and then, for each name from last to first, checks that the global currently holds `nil` and stores the value. A non-nil current value raises the runtime error `global 'a' already defined`. Because the stores happen last to first, a failure on an earlier name leaves later names already assigned.
- `global a, b` without an initializer generates no code and never raises.
- `global function f() ... end` declares `f`, checks that it is currently `nil` (same runtime error), and stores the closure.
- `global a, b from src` is described in section 5.6.

**Pinned** (`global.lus`): re-initializing an existing global raises `already defined` and keeps the old value. Redeclaring without initializer never raises. Clearing the global to `nil` allows a later initialization.

### 4.4 Functions and varargs

**Source:** `lparser.c:parlist`, `body`, `simpleexp` (`TK_DOTS`).

A parameter list is a list of names optionally ending in `...`. The `...` may be followed by a name (`function f(a, ...t)`), which declares `t` as the vararg table parameter (Lua 5.5). Using `...` in a function that is not vararg raises `cannot use '...' outside a vararg function`. The main chunk is always vararg. A malformed parameter raises `<name> or '...' expected`.

`function a.b:c()` adds an implicit first parameter `self`. Assigning a function to a read-only name (`function flags() end`) raises the const error.

### 4.5 Control flow

**Source:** `lparser.c:breakstat`, `gotostat`, `labelstat`, `createlabel`, `solvegotos`, `leaveblock`.

`break` exits the innermost enclosing loop of the current function, including loops outside an enclosing do-expression (section 5.8). Outside any loop it raises `break outside loop`. `goto` and labels follow Lua 5.5: a label may not repeat a label visible in the current function (`label 'x' already defined on line N`), an unresolved goto raises `no visible label 'x' for <goto> at line N`, and jumping into the scope of a local raises `<goto x> at line N jumps into the scope of 'y'`.

### 4.6 Multiple results

**Source:** `lparser.c:hasmultret`, `lcode.c:luaK_setreturns`, `luaK_setoneret`, `luaK_dischargevars`.

Four expression kinds produce a variable number of values: function calls, `...`, `catch` expressions, and do-expressions. They follow one rule. In the last position of an expression list (in `local`, assignment, `return`, call arguments, and table constructors) they produce all their values. In every other position, including inside parentheses and as an operand, they are truncated to exactly one value. The single value of a `catch` is its status. The single value of a do-expression is its first provided value (or `nil`). A call inside an optional chain is always truncated to one value (section 5.2).

---

## 5. Lus extensions

### 5.1 Catch

**Source:** `lparser.c:catchexpr`, `catchstat`, `lvm.c:OP_CATCH`, `OP_ENDCATCH`, `catchErrorRecovery`. **Manual:** `acquis-1.mdx`, `acquis-20.mdx`. **Tests:** `catchstat.lus`, `compile-errors.lus`.

#### Syntax

```ebnf
catchexp  = 'catch' [ '[' expr ']' ] expr ;   (* expression *)
catchstat = 'catch' [ '[' expr ']' ] expr ;   (* statement *)
```

The operand is any expression, not only a call. `catch nil`, `catch 1 + 2`, `catch t.x`, `catch do ... end`, and `catch (catch f())` are all valid.

#### Static semantics

- A catch at statement start is a catch statement. Everywhere else it is a catch expression.
- The bracketed handler is an arbitrary expression.
- **Legacy limit.** The bytecode of the protected operand is limited to 255 instructions because the error-path offset is an 8-bit field. A larger operand raises `catch expression too large (max 255 instructions)`. This is an encoding artifact. The rewrite may lift it, and should keep a clear error if it keeps a limit.

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
local function values() return "a", "b", "c" end
local ok, a, b, c = catch values()          -- true, "a", "b", "c"

local function none() end
print(select('#', catch none()))            -- 1 (just true)

local ok2, err = catch[function(e) return "H", "I" end] error("x")
-- ok2 == false, err == "H" (extra handler results are dropped)

print((catch error("e")))                   -- false
local ok3 = catch f()                       -- only the status

catch cleanup()                             -- statement form
```

**Pinned** (`compile-errors.lus`): `catch noop()` for a zero-result `noop` yields `true` and a `nil` second value, with no spurious extra result. **Pinned** (`catchstat.lus`): side effects before the error persist, registers do not leak across many catch statements or loop iterations, and to-be-closed variables inside the operand are closed on a caught error.

### 5.2 Optional chaining

**Source:** `lparser.c:suffixchain` (case `'?'`), `discharge2basereg`, `exprstat`, `restassign`. **Manual:** `acquis-2.mdx`. **Tests:** `optchain.lus`, `compile-errors.lus`, `syntax-interactions.lus`.

#### Syntax

`?` is a postfix suffix that may appear anywhere in a suffix chain:

```lus
t?.a        t?[k]        t?:m(x)        f?()        t?.list[2,]        t?
```

#### Static semantics

- Once a chain contains a `?`, the whole chain from the first `?` onward is an rvalue. It cannot be an assignment target and it cannot be a call statement. Both forms raise `syntax error` near the next token.
- Calls that appear after the first `?` in a chain are not eligible for stdlib intrinsification (they always compile as ordinary calls).

**Pinned** (`compile-errors.lus`): `t?.a = 1`, `t?[1] = 1`, `t?.a.b = 1`, `h?() = 1`, and `t?.x = 1, 2` all fail with `syntax error near '='`. `local t = {} t?.a` fails with `syntax error near <eof>`.

**Legacy behavior** (verified, and **pinned** by `optchain.lus` "optional call is an expression, not a statement"): `obj?:process()` and `f?()` as statements fail with `syntax error`. The manual pages show `obj?:process()` as a statement, which the implementation rejects. The rewrite follows the implementation. The statement form is written `local _ = obj?:process()`.

#### Dynamic semantics

The chain is evaluated left to right. The part before the first `?` evaluates normally, so `a.b?.c` raises if `a` is `nil`. At each `?`, the current value is tested for truthiness.

- If the value is `nil` or `false`, evaluation of the rest of the chain is skipped entirely, including any argument expressions of later calls, and the result of the whole chain is that falsy value itself. `false?.x` is `false`, not `nil`.
- Otherwise evaluation continues with the next suffix. Suffixes without a preceding `?` are not protected. `t?.a.b` raises if `t.a` is `nil`.
- `?` tests only for `nil` and `false`. Other values are indexed or called normally, so `true?.x` raises `attempt to index a boolean value` and `("str")?.rep` returns `string.rep`.
- A call anywhere after the first `?` produces exactly one value, regardless of context. `print(h?.g())` prints only the first result of `h.g()`, and `select('#', t.x?())` is `1`.
- A trailing `?` with no suffix after it (`t?`) yields the value unchanged. Repeated `?` (`t??.a`) is the same as one.

```lus
local cfg = { db = { host = "localhost" } }
local host = cfg?.db?.host                  -- "localhost"
local port = cfg?.server?.port or 8080      -- 8080
local flag = false
assert(flag?.field == false)
local s = nil
assert(s?.list[2,] == nil)                  -- the slice is skipped too
```

**Pinned** (`syntax-interactions.lus`): a nil base suppresses a side-effecting do-expression argument in `x?:m(do ... end)`. `t?.list[2,]` slices when `t.list` exists and raises `attempt to slice a nil value` when `t` exists but `t.list` is nil.

### 5.3 Slices

**Source:** `lparser.c:suffixchain` (case `'['`), `lvm.c:luaV_slice`, `slice_index`, `OP_SLICE`. **Manual:** `acquis-16.mdx`. **Tests:** `slices.lus`, `syntax-interactions.lus`, `compile-errors.lus`.

#### Syntax

```lus
obj[a, b]     obj[a,]     obj[, b]     obj[,]
```

A slice is a suffix and can appear anywhere an index can, including after `?` and inside longer chains (`t.list[2,4]?[1]`).

#### Static semantics

A slice is an rvalue. **Pinned** (`compile-errors.lus`): `t[1, 2] = {9, 9}` and `t[,] = 5` fail with `syntax error near '='`, `t[1,], x = 1, 2` fails with `syntax error near ','`, and `t[1, 2, 3]` fails with `']' expected near ','`.

#### Dynamic semantics

The object is evaluated first, then the start bound, then the end bound. An omitted bound is `nil`. Then the slice dispatches on the object's type.

Bound conversion for the built-in slices: `nil` takes the default, an integer is used as is, a float with an exact integer value or a string convertible to such a number is converted, and anything else raises `slice index must be an integer`.

**Strings.** The default start is 1 and the default end is the length. The start is raised to 1 if smaller and the end is lowered to the length if larger. Then:

- If start > end after clamping, the result is reversed: the bytes from start down to end. If start is past the length, the result is empty.
- If the end is below 1 or the start is past the length, the result is the empty string.
- Otherwise the result is the bytes from start to end inclusive.

`("hello")[2,4]` is `"ell"`, `("hello")[4,2]` is `"lle"`, `("hello")[-3,2]` is `"he"`, `("hello")[2,100]` is `"ello"`, `("hello")[0,2]` is `"he"`.

**Vectors.** Same rules as strings, producing a new vector.

**Tables.** If the table has a `__slice` metamethod, it is called as `__slice(t, start, end)` with the raw bound values (including `nil` for omitted bounds, with no conversion) and its first result is the slice. Otherwise the built-in slice applies. The default start is 1 and the default end is the border `#t` (raw length). Bounds are not clamped. If start > end the result is reversed. The result is a fresh table whose element `j` (from 1) is `t[i]` for the `j`-th index `i` walked from start to end in steps of +1 or -1, leaving holes where `t[i]` is absent. A span of more than 2^26 elements raises `slice span too large`. `t[0,2]` on `{1,2,3}` yields a table with `[2] = 1, [3] = 2`.

**Other types.** If the value has a `__slice` metamethod it is called as above. Otherwise the runtime raises `attempt to slice a TYPE value`.

```lus
local t = {1, 2, 3, 4, 5}
local a = t[2,4]      -- {2, 3, 4}
local b = t[,3]       -- {1, 2, 3}
local c = t[2,]       -- {2, 3, 4, 5}
local d = t[4,2]      -- {4, 3, 2}
local e = t[,]        -- shallow copy of the sequence
```

**Pinned** (`slices.lus`): reversed slices produce reversed results, slicing an inline constructor `({...})[a,b]` works, and the result is an independent copy.

### 5.4 String interpolation

**Source:** `llex.c:read_interp_section`, `lparser.c:interpexp`, `lvm.c:luaV_tostring`, `OP_TOSTRING`. **Manual:** `acquis-21.mdx`. **Tests:** `interp.lus`, `compile-errors.lus`, `syntax-limits.lus`, `syntax-interactions.lus`.

Lexing is described in section 1.8.

#### Static semantics

- `$name` resolves `name` exactly like a plain variable reference, including global declaration checks. **Pinned** (`compile-errors.lus`): `global ce_g7 return `value $missingInterpName`` fails with `variable 'missingInterpName' not declared`.
- `$name` takes only the identifier characters. `$t.x` interpolates `t` followed by the literal text `.x`. `$x_1!` interpolates `x_1`.
- **Legacy behavior** (verified): the name after `$` is not checked against reserved words. `` `$true` `` and `` `$nil` `` resolve a variable literally named `true` or `nil`, which is a global lookup that yields `nil` in practice. The rewrite should keep this or reject reserved words after `$` with a clear error. It must not reinterpret them as the literals.
- Each part occupies a register until the final concatenation, so a string with very many parts can exceed the register limit. **Pinned** (`syntax-limits.lus`): 255 `$(i)` segments compile, 400 fail with `too many registers`.

#### Dynamic semantics

Parts are processed left to right. Each non-empty literal section becomes a string constant. Each `$name` or `$(expr)` is evaluated and immediately converted to a string before the next part is evaluated. `$(expr)` is truncated to one value. The conversion is the internal `tostring` operation, independent of the global `tostring`:

- strings are used as is,
- integers and floats use the standard number formatting (`1.0` stays `"1.0"`),
- `nil`, `true`, and `false` become `"nil"`, `"true"`, `"false"`,
- any other value with a `__tostring` metamethod calls it. A non-string result raises `'__tostring' must return a string`.
- any other value becomes `"TYPENAME: 0xADDRESS"`, where `TYPENAME` honors `__name`.

The result is the concatenation of all parts in order. An empty interpolated string is `""`. A string with only literal text is that text.

```lus
local name, age = "Alice", 30
print(`Hello, $name!`)                -- Hello, Alice!
print(`Next year: $(age + 1).`)       -- Next year: 31.
print(`$$5 and \`ticks\``)            -- $5 and `ticks`
print(`$(nil) $(1.0)`)                -- nil 1.0
```

**Pinned** (`interp.lus`): interpolation works when the global `tostring` is `nil` or shadowed. **Pinned** (`syntax-interactions.lus`): a yield inside an interpolated expression resumes correctly, a do-expression inside `$(...)` providing two values renders the first, and one without `provide` renders `nil`.

### 5.5 Enums

**Source:** `lparser.c:enumexpr`, `lenum.c`. **Manual:** `acquis-5.mdx`. **Tests:** `enum.lus`, `compile-errors.lus`, `syntax-limits.lus`.

#### Syntax

```ebnf
enumexp = 'enum' Name { ',' Name } 'end' ;
```

#### Static semantics

- `enum` is an expression only. **Pinned**: `enum a, b end` as a statement fails with `unexpected symbol near 'enum'`.
- At least one member is required. Members are names (reserved words are rejected). A trailing comma is rejected.
- Duplicate members raise `duplicate enum member 'a'`.
- At most 255 members (`too many names in enum`). **Pinned** (`syntax-limits.lus`): 255 compile, 256 fail.
- The closing `end` error is always the short form `'end' expected near TOKEN` (the parser passes the current line as the opening line).

**Pinned** (`compile-errors.lus`):

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

The compiler creates the enum root and its first member at compile time and stores the member as a constant of the enclosing function. Evaluating the expression loads that constant. Consequently every evaluation of the same `enum ... end` expression (for example in a loop or across calls of the same function) yields the identical enum, while two textually distinct `enum` expressions always yield distinct enums even with the same member names.

The value of the expression is the first member. Members support indexing by name and by 1-based position from any member of the same enum (`e.x.y == e.y`, `e[1][3] == e.z`), ordering comparisons within one enum (comparing members of different enums raises), equality by identity, `tonumber` giving the 1-based position, `type` giving `"enum"`, and use as table keys.

```lus
local color = enum red, green, blue end
assert(color == color.red)
assert(color[2] == color.green)
assert(color.red < color.blue)
assert(tonumber(color.blue) == 3)
```

### 5.6 `from` destructuring

**Source:** `lparser.c:localstat`, `localfrom`, `localfromgroup`, `globalnames`, `globalfrom`, `restassign`, `assignfrom`, `assigncond`, `checkgroupsource`. **Manual:** `acquis-4.mdx`. **Tests:** `from.lus`, `compile-errors.lus`, `syntax-interactions.lus`, `groups.lus`.

#### Syntax

```lus
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
- **Legacy defect** (verified). In the assignment form, a global target whose name happens to be constant number 0 of the function is rejected with `'from' requires simple variable names`. For example `x, y from {x=1, y=2}` as the first statement of a chunk fails while `local q = "zz" x, y from {...}` works. The rewrite must accept every global target.

**Pinned** (`compile-errors.lus`): `t.x from s` fails with `'from' requires simple variable names`. `local a from` fails with `unexpected symbol near <eof>`. `local from t` fails with `<name> expected near 'from'`. `from x` fails with `unexpected symbol near 'from'`. `local a, from {a=1}` fails with `<name> expected near 'from'`.

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
local t = setmetatable({}, { __index = function(_, k) return k .. "!" end })
local p, q from t                  -- p == "p!", q == "q!"
local cfg = { host = "h", port = 1 }
local port, host from cfg          -- order of names is free
local x, y
x, y from { x = 1, y = 2 }
```

**Pinned** (`from.lus`): the source expression runs once even when extracting several fields, the array part is ignored, and missing fields become `nil`. **Pinned** (`syntax-interactions.lus`): `local a from nil` raises under `catch`, and `while x from t do ... end` drains a field until it becomes `nil`.

### 5.7 Assignment conditions in `if`, `elseif`, and `while`

**Source:** `lparser.c:isassigncond`, `assigncond`, `test_then_block`, `ifstat`, `whilestat`, `skipdeadclause`. **Manual:** `acquis-3.mdx`, `acquis-13.mdx`. **Tests:** `ifassign.lus`, `whileassign.lus`, `syntax-interactions.lus`, `compile-errors.lus`, `attrs2.lus`.

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
- If any name is `<group>`, all must be (`cannot mix <group> with non-group variables in condition`), `<close>` is rejected (`cannot use <close> with <group> variables`), and each value must be a group constructor or a group name. Group conditions are always true.

**Pinned** (`compile-errors.lus`):

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

Because the `while` variables are one binding, closures created in different iterations share them. **Pinned** (`syntax-interactions.lus`): closures created in a while-assignment loop all observe the value at break time, or the final falsy value after normal exit, and a body-local copy restores per-iteration capture. Closures over `if` condition variables capture the value of that `if` statement.

```lus
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

**Source:** `lparser.c:doexpr`, `providestat`, `provideneedsclose`, `leaveblock`, `doexpr_minfreereg`, `lvm.c:OP_PROVIDE`, `OP_ENDDO`. **Manual:** `acquis-23.mdx`. **Tests:** `doexpr.lus`, `compile-errors.lus`, `syntax-interactions.lus`, `syntax-limits.lus`.

#### Syntax

```ebnf
doexp       = 'do' block 'end' ;            (* only in expression position *)
providestat = 'provide' [ explist ] ;       (* must be the last statement of its block *)
```

#### Static semantics

- `do` in expression position is a do-expression. `do` at statement start is a plain block (section 2.1).
- `provide` is valid anywhere inside the body of a do-expression of the same function, at any block depth, including inside loops and `if` branches. The innermost enclosing do-expression is the target. Outside a do-expression, including directly inside a plain `do` statement and inside a function literal nested in a do-expression, it raises `'provide' outside do expression`.
- `provide` ends its block. A statement after it raises `'end' expected near TOKEN` (or the corresponding block terminator message). `provide` takes no trailing `;`.
- The body is an ordinary scope. Locals declared inside are not visible outside.
- `break`, `goto`, and `return` inside a do-expression behave as in any block: `break` may exit a loop outside the do-expression, `goto` may jump to a label outside, and `return` returns from the enclosing function. The do-expression then produces no value.

**Pinned** (`compile-errors.lus`): `provide 1`, `do provide 1 end`, and `local x = do local f = function() provide 1 end provide 2 end` fail with `'provide' outside do expression`. `local x = do provide 1 local y = 2 end` fails with `'end' expected near 'local'`. `local x = do provide 1 provide 2 end` fails with `'end' expected near 'provide'`. `local x = do for i = 1, 2 do provide i end end` compiles and yields 1.

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
end                                   -- 20

local a, b = do provide 1, 2 end      -- 1, 2
local n = 1 + do provide 2 end * 3    -- 7
local ok, v = catch do provide risky() end
local w = do
    for i = 1, 10 do
        if i * i > 20 then provide i end
    end
    provide -1
end                                   -- 5
```

**Pinned** (`doexpr.lus`): nested do-expressions to three levels, provide in either branch of an `if`, early provide from a loop, fewer or more provided values than targets, and access to and mutation of outer locals and upvalues. **Pinned** (`syntax-limits.lus`): very deep nesting fails gracefully with a `stack overflow` message.

**Legacy note.** `acquis-23.mdx` shows `local x <group> = do ... provide y end`. The parser accepts only a constructor or a group name after `<group> =`, so this form fails with `unexpected symbol`. The manual is wrong here.

### 5.9 Attributes

**Source:** `lparser.c:parseattributes`, `parse_runtime_attr`, `isbuiltin_attr`, `getvarattribute`, `localstat`, `call_runtime_attrs`, `storevar_with_attrs`, `groupconstructor_attrs`. **Manual:** `acquis-22.mdx`. **Tests:** `runtime-attrs.lus`, `attrs2.lus`, `compile-errors.lus`.

#### Syntax

```ebnf
attribs  = '<' attrib { ',' attrib } '>' ;
attrib   = 'const' | 'close' | 'group' | subexpr(3) ;
```

The attribute list follows the variable name. It is never placed before `local`. (`acquis-22.mdx` says "prior to the local keyword", but its own examples and the parser put the list after the name.)

#### Where each kind is allowed

| Position | Compile-time | Runtime |
| --- | --- | --- |
| `local` with one name and `=` or no initializer | yes | yes |
| `local` with several names | yes | `runtime attributes not supported with multiple variables` |
| `local ... from` | `const`, `group` path | `runtime attributes not supported with 'from'` |
| `local g <group, h> = { ... }` | yes | yes, applied to every field (see 5.10) |
| group fields | yes | `runtime attributes not supported in this context` |
| assignment conditions | yes | `runtime attributes not supported in this context` |
| `global` (prefix and per name) | `const` only | `runtime attributes not supported in this context` |
| `for` variables, parameters | no attribute syntax | no attribute syntax |

Compile-time attributes must come before runtime attributes in one list. **Pinned** (`attrs2.lus`): `<h, const>` fails with `compile-time attribute 'const' must come before runtime attributes`, and `<h, close>` fails similarly with `'close'`.

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
- the initialization and direct field assignment `g.f = v` of fields of a group declared with runtime attributes, with the name `"g.f"`.

Handlers do not run on:

- assignments made from a nested function through an upvalue (the value is stored as written),
- a group overwrite `g = { f = v }` (verified, the fields are stored directly),
- assignments to fields of a subgroup of an attributed group after initialization.

Ordering with `<close>` and `<const>`: with `<close, h>`, the handler runs on initialization and then the resulting value is marked to be closed. With `<const, h>`, the handler runs on the single initialization and the variable is a register-held read-only local.

```lus
local function only(kind)
    return function(name, value)
        if type(value) ~= kind then error(`$name: expected $kind`) end
        return value
    end
end
local n <only "number"> = 10
n = 20                       -- checked
n = nil                      -- handler skipped

local function first(name, v) return v + 1 end
local function second(name, v) return v * 2 end
local x <first, second> = 10 -- 22
```

**Pinned** (`attrs2.lus`): the attribute expression runs exactly once and before the initializer, a declaration without initializer skips the handler, shadowed attributed locals dispatch to their own handlers, an upvalue write from a closure does not re-invoke the handler, and a handler returning `false` sets the variable to `false`.

### 5.10 Local groups

**Source:** `lparser.c:localstat` (group path), `groupconstructor_attrs`, `suffixedexp` (group mode), `exprstat` (group overwrite), `assigncond`, `localfromgroup`, `assignfrom`, `findgroup`, `findgroupfield`. **Manual:** `acquis-18.mdx`. **Tests:** `groups.lus`, `compile-errors.lus`, `attrs2.lus`, `from.lus`.

#### Syntax

```lus
local z <group> = { a = 1, b <const> = 2, c <group> = { d = 3 } }
local y <group> = z                 -- copy
z = { a = 10 }                      -- overwrite of listed fields
z.a = 5                             -- field assignment
print(z.c.d)                        -- subgroup field
local a, b from z                   -- group source
```

#### Static semantics

- A group is a compile-time namespace. Each non-subgroup field is a real local variable that holds the field value. The group name itself has no runtime value.
- In a `local` statement, if any name is `<group>`, all must be (`cannot mix <group> with non-group variables`), `<close>` is rejected (`cannot use <close> with <group> variables`), and `=` is required. Each initializer is a group constructor or a group name. Several groups may be declared in one statement, separated by commas.
- A group constructor contains only `Name [attribs] = value` fields. Separators `,` or `;` are required between fields and a trailing separator is allowed (`expected ',' or ';' in group constructor`). A `<group>` field takes a nested constructor and declares a subgroup. Bracketed keys and positional items are rejected with `<name> expected near TOKEN`. **Pinned** (`compile-errors.lus`): `{ [1] = 2 }` fails with `<name> expected near '['` and `{ 1, 2 }` fails with `<name> expected near '1'`.
- A group name is usable only as the prefix of a field path (`g.f`, `g.sub.f`), as the target of a group overwrite, as the value of another group's initializer, and as a `from` source. Anywhere else, including as a call argument, after `?`, or alone, it raises `cannot pass local group`. A group-copy initializer that is not a group name raises `group can only be copied from another group`.
- A field path naming an absent field raises `'f' is not a field of group 'g'`, for reads and writes alike.
- `<const>` fields reject assignment with the const error. **Pinned**: `local z <group> = { a = 1, b <const> = 2 } z.b = 3` fails with `attempt to assign to const variable 'b'`.
- A group overwrite `g = { ... }` accepts only a constructor (`group can only be assigned a constructor or another group`), and every listed field must already exist (`'d' is not a field of group 'z'`). Subgroups cannot be overwritten (`cannot overwrite subgroups`). Separators follow the constructor rule (`expected ',' or ';' in group overwrite`).
- Groups are always local. `global g <group>` raises `global variables cannot be groups`.

#### Dynamic semantics

- Initialization evaluates field values in source order and stores each into its field local.
- A copy `local y <group> = z` copies the current values of `z`'s non-subgroup fields into new locals. Subgroup fields of `y` refer to the same field locals as `z`'s subgroups (verified: after the copy, `y.c.d = 42` also changes `z.c.d`).
- An overwrite evaluates each listed value in source order and stores it into the existing field. Unlisted fields keep their values.
- With runtime attributes on the group (`local g <group, h> = {...}`), handlers run per field as described in section 5.9.

#### Legacy defects

The legacy group implementation has several scoping defects. The rewrite should implement the intended semantics stated here, which the tests and manual imply.

1. **Field names leak into scope** (verified). Each field local is registered under the bare field name, so after `local z <group> = { a = 1 }`, a plain `a` resolves to the field and shadows any outer `a`. This contradicts the stated use case of avoiding name conflicts. Intended: field locals are reachable only through the group path.
2. **Groups in nested functions** (verified). Inside a nested function, `z.a` for an outer group `z` captures the wrong register and fails at runtime (`attempt to index a number value (upvalue 'z')`). Intended: a field path from a nested function captures the field local as an upvalue.
3. **Group lookup by name ignores scope** (verified). Group descriptors are found by name in a list that is never pruned, newest first. `local g <group> = {a=1} do local g <group> = {b=2} end print(g.a)` fails with `'a' is not a field of group 'g'`. Intended: lexical resolution to the innermost group in scope.
4. **`<close>` fields** are accepted, are read-only, and are never closed. Intended: either close them at scope exit like any `<close>` local, or reject `<close>` on group fields.
5. Handler names for fields of a subgroup of an attributed group use only the subgroup name (`"c.d"` for the field `d` of subgroup `parent.c`).

### 5.11 Flags and compile-time folding

**Source:** `lparser.c:foldflagcond`, `test_then_block`, `ifstat`, `deadblock`, `skipdeadclause`, `savecode`, `restorecode`, `buildvar` (`flags` case), `new_varkind_attrs`, `lua.c:create_flags_table`, `lua.c` option `-F`. **Manual:** `acquis-28.mdx`. **Tests:** `flags.lus`.

#### The `flags` table

The CLI options `-F NAME`, `-FNAME`, `-F NAME=VALUE`, and `--flag NAME[=VALUE]` populate a read-only table exposed as the global `flags`. A flag without `=` is `true`. A value that parses as a numeral becomes a number. Any other value, including an empty one, becomes a string. A repeated flag keeps its last value. The table always exists in the CLI, even without flags. Workers see the same table.

#### Static semantics of the name `flags`

- `flags` is a reserved pseudo-global. A free reference to `flags` is always allowed, even under a strict `global` declaration.
- Assigning to the free name raises `attempt to assign to const variable 'flags'`. This includes `function flags() end`.
- Declaring it as a global raises `cannot declare 'flags' (reserved name)`. This includes `global flags`, `global function flags`, and any other global declaration form.
- Locals may shadow it. `local flags = {}` is valid, and a shadowed `flags` never folds.
- Writing a field (`flags.x = 1`) compiles and fails at runtime because the table is read-only.

#### Folding

Folding applies to the condition of an `if` or `elseif` clause when all of the following hold:

- the condition is a plain expression (not an assignment condition),
- no AST is being built (tools such as `debug.parse` and the language server always see the full tree),
- the interpreter has a flags table (the CLI creates one, `lusc` and a bare embedding do not),
- the condition is exactly `flags.NAME`, `flags["NAME"]`, `not flags.NAME`, or `not flags["NAME"]`, where `flags` is the free reserved name.

Any other shape compiles normally and reads the table at runtime, including parenthesized lookups, comparisons, and `and`/`or` chains. `while`, `repeat`, and expressions outside conditions never fold.

A folded condition is true when the flag is present and truthy, negated for the `not` form. An absent flag is `nil`, so it is false.

- If a clause folds false, its block is fully parsed and checked and then its generated code is discarded. Evaluation continues with the next clause.
- If a clause folds true, its block is compiled normally and every later `elseif` and `else` clause is fully parsed and checked and then discarded.
- Discarded code leaves no trace: no instructions, no pending `break` or `goto` targets, no labels, no nested prototypes, no debug locals, and correct line information afterwards. Constants and upvalues created while parsing a discarded block may remain in the function (this is invisible to programs).
- Folding decisions are made at compile time with the flags of the compiling process and are baked into dumped bytecode.

```lus
-- lus -Fdebug script.lus
if flags.debug then
    enableTracing()        -- compiled
else
    quiet()                -- parsed, checked, discarded
end
if flags.name == "alpha" then   -- not foldable, runtime read
    print("alpha")
end
```

**Pinned** (`flags.lus`): dead branches are still syntax checked, line numbers stay correct after folded branches, a `break` inside a dead branch does not affect the loop, closures and `<close>` locals in dead branches do not disturb live code, a `goto` in a dead branch is dropped, nested folds work, and the folded chunk is much smaller than the unfolded control.

### 5.12 Queries

**Source:** `lparser.c:queryexpr`, `querysource`, `qexpr`, `qsimple`, `qaggregate`, `qparam`, `qclosure`, `qb_node_uses_row`, `qb_serialize`, `lcode.c:luaK_query`, `lvm.c:OP_QUERY`, `lquery.c`, `lquery.h`. **Manual:** `acquis-34.mdx`. **Tests:** `query_syntax.lus`, `query.lus`, `query2.lus`, `query_sqlite.lus`.

#### Syntax

The grammar is in section 2. A query begins with `@`, lists one or more comma-separated sources, and continues with clauses in any order.

```lus
local adults =
  @people as p
   where p.age > 18
   select p.name, p.age
   order by p.age desc
   limit 100
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

Complexity limits raise `query too complex`: 256 plan nodes, 200 operands (parameters plus host closures), 2048 bytes of interned names, 32 select items, 16 group keys, 16 order items, and 10 names per chain.

**Legacy defect.** Clause expressions nested deeper than 64 levels compile but fail when the query value is built, with `corrupt query plan in bytecode`. The rewrite should reject them at compile time with `query too complex`.

**Manual claim not enforced.** `acquis-34.mdx` states that bare boolean columns in clauses are compile-time errors. The legacy parser has no such check. The rewrite should decide explicitly and add a test either way.

#### Dynamic semantics

Evaluating a query expression evaluates the sources left to right, then the bound parameters and host closures in clause parse order, and builds a value of type `query` that holds them together with the plan. The query is lazy and does nothing further until run by the `query` iterator. Execution semantics (the fixed pipeline, provider push-down, nil and NaN ordering, aggregate rules) are a library concern documented in `acquis-34.mdx` and `h1/query.lus`.

**Pinned** (`query_syntax.lus`): clause words work as ordinary locals, fields, and methods outside queries. `@` inside comments and strings is inert. Queries appear in every expression position. A query ends at the first unrelated name. Clause order is free. `return @` and `@t as` (truncated) fail with an `expected` message. Each pair of query values built separately is distinct. A query is not closable, cannot cross a worker boundary, and survives `string.dump`.

### 5.13 Compile-time call rewrites

**Source:** `lparser.c:funcargs`, `check_fastcall`, `check_require`, `retstat`, `lfastcall.c`.

Two rewrites change the generated code without changing observable semantics. They are listed here so the rewrite can reproduce or deliberately omit them.

- **Fastcall.** A call whose callee is a free name read through `_ENV` (such as `type(x)` or `math.floor(x)`), with a fixed argument count, outside optional chains and method calls, and when fastcalls are enabled, compiles to an intrinsic that falls back to the ordinary call whenever the callee is not the original builtin. Parity rules are in `AGENTS.md` under "Stdlib Fastcall Parity".
- **Preincluded `require`.** Under a read-only environment with preincluded modules, `require("literal")` naming a preincluded module compiles to a direct module load (`OP_REQUIRE`).

---

## 6. Compile-time error catalog

### 6.1 Message format

All compile errors are raised as `LUA_ERRSYNTAX` with a single string message.

- **Syntax errors** (`luaX_syntaxerror`, `check`, `checknext`, `check_match`, `check_condition`) have the form `CHUNK:LINE: MESSAGE near TOKEN`, where `LINE` is the line of the current token and `TOKEN` is the current token. Fixed tokens and keywords appear in single quotes (`'end'`, `'='`). Names, strings, and numerals appear as their source text in single quotes (`'foo'`). End of input appears as `<eof>`. Interpolation tokens appear as `<interp_begin>`, `<interp_mid>`, `<interp_end>`, or `<interp_simple>`.
- **Semantic errors** (`luaK_semerror`) have the form `CHUNK:LINE: MESSAGE` with no `near` part, where `LINE` is the line of the last consumed token.
- **`check_match`** produces `'X' expected near TOKEN` when the opener is on the current line and `'X' expected (to close 'Y' at line N) near TOKEN` otherwise.
- **Limits** produce `too many WHAT (limit is N) in main function` or `... in function at line N`.
- **Chunk names**: a name beginning with `=` or `@` is shown without that prefix. Any other name is shown as `[string "..."]`, truncated.
- Recursion in the parser is bounded (200 nested levels of statements and expressions). Exceeding it raises an error whose message contains `stack overflow`.

### 6.2 Messages specific to Lus

| Message | Kind | Raised by |
| --- | --- | --- |
| `unfinished interpolated string` | lexical | `read_interp_section` |
| `invalid interpolation after '$'` | lexical | `read_interp_section` |
| `invalid escape sequence in interpolated string` | lexical | `read_interp_section` |
| `catch expression too large (max 255 instructions)` | syntax | `catchexpr`, `catchstat` |
| `'provide' outside do expression` | syntax | `providestat` |
| `too many names in enum` | syntax | `enumexpr` |
| `duplicate enum member 'X'` | semantic | `enumexpr` |
| `'from' requires simple variable names` | syntax | `assignfrom` |
| `cannot use 'from' with to-be-closed variables` | semantic | `localstat`, `assigncond` |
| `cannot use 'from' with <group> variables` | semantic | `assigncond` |
| `runtime attributes not supported with 'from'` | semantic | `localstat` |
| `runtime attributes not supported with multiple variables` | semantic | `localstat` |
| `runtime attributes not supported in this context` | semantic | `getvarattribute` |
| `compile-time attribute 'X' must come before runtime attributes` | semantic | `parseattributes` |
| `conflicting attributes` | semantic | `parseattributes` |
| `multiple to-be-closed variables in condition` | semantic | `assigncond` |
| `cannot mix <group> with non-group variables` | semantic | `localstat` |
| `cannot mix <group> with non-group variables in condition` | semantic | `assigncond` |
| `cannot use <close> with <group> variables` | semantic | `localstat`, `assigncond` |
| `group can only be copied from another group` | semantic | `localstat`, `assigncond` |
| `group can only be assigned a constructor or another group` | semantic | `exprstat` |
| `cannot pass local group` | semantic | `suffixedexp` |
| `'X' is not a field of group 'G'` | semantic | `suffixedexp`, `exprstat`, `localfromgroup`, `assignfrom` |
| `cannot deconstruct subgroup 'X' with 'from'` | semantic | `localfromgroup`, `assignfrom` |
| `cannot overwrite subgroups` | semantic | `exprstat` |
| `expected ',' or ';' in group constructor` | semantic | `groupconstructor_attrs` |
| `expected ',' or ';' in group overwrite` | semantic | `exprstat` |
| `global variables cannot be groups` | semantic | `getglobalattribute` |
| `cannot declare 'flags' (reserved name)` | semantic | `new_varkind_attrs` |
| `nested queries are not supported` | semantic | `queryexpr`, `qsimple` |
| `too many sources in query` | semantic | `querysource` |
| `query source index must be a literal` | semantic | `querysource` |
| `query source needs an 'as' name` | semantic | `querysource` |
| `duplicate row variable 'X' in query` | semantic | `querysource` |
| `duplicate 'CLAUSE' clause in query` | semantic | `queryexpr` |
| `'by' expected after 'group'`, `'by' expected after 'order'` | semantic | `queryexpr` |
| `'as' name expected for this projection` | semantic | `queryexpr` |
| `'select' needs at least one projection` | semantic | `queryexpr` (unreachable in practice) |
| `a join requires a 'select' clause` | semantic | `queryexpr` |
| `query limit must be row-independent`, `query offset must be row-independent` | semantic | `queryexpr` |
| `aggregate 'X' is only allowed in 'select' or 'having'` | semantic | `qsimple` |
| `aggregates cannot nest` | semantic | `qaggregate` |
| `'*' is only allowed in count` | semantic | `qaggregate` |
| `operator not supported in a query clause` | semantic | `qexpr` |
| `a suffix on a parenthesized expression is not supported in a query clause` | semantic | `qsimple` |
| `query too complex` | semantic | query builder |

### 6.3 Messages inherited from Lua 5.5

`unexpected symbol`, `syntax error`, `'X' expected`, `'X' expected (to close 'Y' at line N)`, `<name> expected`, `<name> or '...' expected`, `function arguments expected`, `'=' or 'in' expected`, `break outside loop`, `cannot use '...' outside a vararg function`, `attempt to assign to const variable 'X'`, `variable 'X' not declared`, `_ENV is global when accessing variable 'X'`, `global variables cannot be to-be-closed`, `multiple to-be-closed variables in local list`, `label 'X' already defined on line N`, `no visible label 'X' for <goto> at line N`, `<goto X> at line N jumps into the scope of 'Y'`, `control structure too long`, and the limit messages for `local variables`, `upvalues`, `registers`, `multiple results`, `returns`, and `items in a constructor`.

### 6.4 Runtime errors introduced by Lus syntax

| Message | Construct |
| --- | --- |
| `attempt to use a TYPE value as a catch handler` | `catch[h]` with a non-function handler |
| `slice index must be an integer` | slice bound of the wrong type |
| `slice span too large` | table slice over 2^26 elements |
| `attempt to slice a TYPE value` | slice of a value without slice support |
| `'__tostring' must return a string` | interpolation of a value whose `__tostring` returns a non-string |
| `global 'X' already defined` | initializing `global` declaration or `global function` |
| `corrupt query plan in bytecode` | malformed or over-deep query plan |

---

## 7. Edge cases and legacy defects at a glance

### 7.1 Behavior the rewrite must reproduce

1. `if a <b then` is an attribute list, `if a < b then` is a comparison (section 2.1).
2. `local x <const>= 1` fails because `>=` is one token.
3. `do` at statement start is always a block. `while x = do end` consumes `do` as a do-expression.
4. `catch` extends rightward over a full expression. In single-value position it yields only its status.
5. Optional chains are rvalues. A chain that ends in a call cannot be a statement. Calls in a chain yield exactly one value. Short-circuit returns the falsy value itself.
6. Slices clamp for strings and vectors, never for tables, and reverse when start > end. Numeric strings are accepted as bounds.
7. `$name` takes only identifier characters and resolves reserved words as variable names.
8. An `enum` expression is a constant of its function: re-evaluation yields the same enum.
9. `from` reads fields left to right through `__index` and stores right to left.
10. `while` assignment variables are one shared binding across iterations.
11. `provide` may jump out of loops and nested blocks. `break`, `goto`, and `return` may leave a do-expression. `provide` takes no trailing `;`.
12. Runtime attribute handlers are skipped for `nil`, ignore `nil` results, and do not run for upvalue writes or group overwrites.
13. Group copies share subgroups with their source.
14. Folding only touches `if`/`elseif` with the four exact shapes and never runs when an AST is built.
15. A query ends at the first token that is not a clause keyword. `order by name` with a non-row name is an alias reference. Aggregate names followed by `(` are always aggregates inside clauses.
16. `global *` anywhere in scope re-enables free names below later named declarations.

### 7.2 Legacy defects to fix

| Defect | Section | Recommendation |
| --- | --- | --- |
| `$(expr)` followed by a non-interpolation token crashes | 1.8.2 | check the token and raise a syntax error |
| nested interpolated strings with their own interpolations break | 1.8.2 | lex with a mode stack |
| `from` rejects a global target that is constant 0 | 5.6 | accept every `_ENV` global target |
| group fields leak as plain locals | 5.10 | hide field locals from plain resolution |
| group paths in nested functions read the wrong register | 5.10 | capture field locals as upvalues |
| group lookup ignores scope | 5.10 | resolve groups lexically |
| `<close>` group fields are never closed | 5.10 | close them or reject the attribute |
| query clause depth over 64 fails only at runtime | 5.12 | reject at compile time |
| `catch` operand limited to 255 instructions | 5.1 | lift the limit or keep a clear error |

### 7.3 Manual statements that disagree with the implementation

| Manual | Statement | Implementation |
| --- | --- | --- |
| `acquis-2.mdx`, `guide.mdx` | `obj?:process()` used as a statement | syntax error |
| `acquis-22.mdx` | attributes are inserted prior to `local` | attributes follow the name |
| `acquis-23.mdx` | `local x <group> = do ... end` | syntax error |
| `acquis-34.mdx` | bare boolean columns are compile-time errors | unchecked |

---

## 8. Source map

| Topic | Legacy locations |
| --- | --- |
| tokens, keywords | `llex.h:enum RESERVED`, `llex.c:luaX_tokens`, `llex.c:luaX_token2str` |
| numerals | `llex.c:read_numeral`, `lobject.c:luaO_str2num` |
| strings, long brackets | `llex.c:read_string`, `read_long_string`, `skip_sep`, `readutf8esc`, `readdecesc`, `readhexaesc` |
| interpolation | `llex.c:read_interp_section`, `llex.c:llex`, `lparser.c:interpexp`, `lvm.c:luaV_tostring` |
| statements | `lparser.c:statement`, `statlist`, `block_follow` |
| expressions | `lparser.c:subexpr`, `simpleexp`, `suffixedexp`, `suffixchain`, `primaryexp`, `funcargs`, `priority` |
| locals, attributes | `lparser.c:localstat`, `parseattributes`, `parse_runtime_attr`, `getvarattribute`, `call_runtime_attrs`, `storevar_with_attrs` |
| globals | `lparser.c:globalstatfunc`, `globalstat`, `globalnames`, `globalfunc`, `initglobal`, `globalfrom`, `buildvar`, `searchvar`, `lcode.c:luaK_codecheckglobal` |
| assignment | `lparser.c:exprstat`, `restassign`, `assignfrom`, `check_conflict` |
| catch | `lparser.c:catchexpr`, `catchstat`, `lvm.c:OP_CATCH`, `OP_ENDCATCH`, `catchErrorRecovery` |
| optional chaining | `lparser.c:suffixchain`, `discharge2basereg` |
| slices | `lparser.c:suffixchain`, `lvm.c:OP_SLICE`, `luaV_slice`, `slice_index` |
| enums | `lparser.c:enumexpr`, `lenum.c` |
| do-expressions | `lparser.c:doexpr`, `providestat`, `provideneedsclose`, `leaveblock`, `lvm.c:OP_PROVIDE`, `OP_ENDDO`, `lcode.c:luaK_setreturns`, `luaK_setoneret` |
| assignment conditions | `lparser.c:isassigncond`, `assigncond`, `test_then_block`, `ifstat`, `whilestat` |
| groups | `lparser.c:groupconstructor_attrs`, `localstat`, `suffixedexp`, `exprstat`, `localfromgroup`, `findgroup` |
| flags | `lparser.c:foldflagcond`, `deadblock`, `skipdeadclause`, `savecode`, `restorecode`, `lua.c:create_flags_table` |
| queries | `lparser.c:queryexpr`, `querysource`, `qexpr`, `qsimple`, `qclosure`, `qparam`, `qaggregate`, `lcode.c:luaK_query`, `lquery.h`, `lquery.c` |
| call rewrites | `lparser.c:funcargs`, `check_fastcall`, `check_require`, `retstat` |
| error formatting | `llex.c:lexerror`, `luaX_syntaxerror`, `lcode.c:luaK_semerror`, `lparser.c:check_match`, `errorlimit` |
