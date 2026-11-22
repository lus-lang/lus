# Nameless indexing in table constructors

_Status: investigation closed. Lus does not adopt nameless indexing, and this note records why._

_Nameless indexing_ is a proposed expression that reads a field of the table that the innermost enclosing table constructor is building, without naming the table. The proposal has three forms: `.field`, `["field"]`, and `:method(args)`.

```lus nocheck
local counter = {
    value = 1337,
    as_string = function() return tostring(.value) end,
}
print(counter.as_string())   -- 1337
```

This note checks the grammar, the meaning inside nested constructors and inside functions, and the cost.

## 1. Grammar

### Line continuation

Lus ignores line breaks between tokens, so a suffix at the start of a line continues the expression that ends the previous line. The following lines are one statement today, and `x` is `7`. `lus` was run on this exact code.

```lus nocheck
local x = t.f
()
.b
```

A method call continues the same way, and programs rely on it for chains such as `builder\n:add(1)\n:add(2)`. A nameless form therefore cannot start a statement. A line beginning with `.count = 0` inside a function body continues the previous statement whenever that statement ends with an expression that takes a suffix, such as a call. Changing this rule would break method chains, so continuation must win, as it already does for `(`.

Inside an expression the forms are unambiguous. After `=`, `(`, `,`, an operator, `return`, or `{`, no expression has started, and `.`, `[`, and `:` cannot start one today. `.field` therefore parses as nameless indexing exactly where an expression starts. The lexer reads `.5` as a number and `..` as concatenation, so `.field` needs a name right after the dot, which neither of those has.

### Brackets

`["field"]` collides with two existing forms.

- `{ ["k"] = v }` is a field with a computed key. The parser can tell `{ ["k"] }`, a positional item that reads `k`, from `{ ["k"] = v }` only by looking past the closing bracket, and a reader cannot tell them apart at a glance.
- `[[` and `[=` open a long string, so `{ [["k"]] }` is a list holding the string `"k"`, and `{ [[k]] }` is a list holding `"k"` as well. `lus` confirms the second case.

`.[expr]` avoids both collisions, because a dot followed by a bracket appears nowhere in the grammar today. This note uses `.[expr]` as the bracket form from here on.

### Methods

`:method(args)` at the start of an expression is free in the grammar. The token `::` opens a label, and the lexer reads `::` before `:`, so a nameless method call needs a name right after a single colon. That is already the shape of a method call.

## 2. Meaning

### Which table

A nameless index refers to the table of the innermost constructor that lexically encloses it. In `{ a = 1, inner = { b = .a } }`, `.a` reads the field `a` of the inner table, which is `nil`. A nested constructor has no form that reaches the outer table.

### Reads while the table is built

A field value that reads a nameless index at construction time sees the table as built so far. The compiler stores each named field when it evaluates it, but it stores positional items in batches of up to 50 with one instruction. A rule that makes `{ 10, 20, total = .[1] + .[2] }` work requires the compiler to store the pending positional items before any field value that contains a nameless index. With that rule, a read sees every field written to its left. A read of a field to its right sees `nil`.

```lus nocheck
local box = { width = 3, height = 4, area = .width * .height }
print(box.area)   -- 12
```

### Inside functions

A function written inside the constructor that reads `.value` captures the table, as it would capture a local holding it. Each evaluation of the constructor builds a new table and new functions bound to it. The table holds the functions and the functions hold the table, which the collector reclaims like any other cycle.

The captured table is the constructed table, not the receiver of a call. This differs from `self` in two places where Lus programs commonly share functions.

- A prototype with `__index`. `local child = setmetatable({ value = 1 }, { __index = counter })` makes `child.as_string()` read `counter.value`, so it returns `1337`, not `1`.
- A copy. `table.clone(counter)` copies the function, which still reads the original table. The copy's `as_string` reports the original's value after either table changes.

A method written with `self` reads its receiver, so it works for both: `as_string = function(self) return tostring(self.value) end`, called as `counter:as_string()`.

## 3. Cost

A constructor without a nameless index compiles exactly as before, because the forms exist only in the parser and in the code generator of constructors. A read at construction time compiles to one field read on the register that already holds the new table, the same instruction as `t.width` after construction. The flush of pending positional items happens only in constructors that contain a nameless index. A function that reads the table turns that register into a hidden local captured as an upvalue, at the cost of one upvalue per closure, the same as capturing a named local.

The optimizing tier mirrors the stores of a constructor when it builds a table (`runtime/HACKING.md`, "The JIT"). A read in the middle of a constructor makes the partly built table observable, so the tier must keep its mirrored stores in program order up to that read. That is a constraint on the tier, not a cost for programs that leave the forms unused.

## 4. Verdict

The construction-time form is safe and cheap: derived fields such as `area = .width * .height` read earlier fields with no pitfall. The form inside functions, which the motivating example uses, binds to the constructed table and silently gives wrong answers under prototypes and copies, where `self` gives the right one. Statements cannot begin with any of the forms, so a function body cannot assign a field with `.count = .count + 1` on a line of its own.

**Choices**

- **(a) Adopt `.field` and `.[expr]` in the field values of a constructor only, outside nested functions (recommended).** A nameless index inside a function in the constructor is a compile error that suggests `self`. `:method()` is left out, because a method that the constructor itself calls during construction has no common use.
- (b) Adopt all three forms everywhere inside the constructor, including nested functions, with the receiver pitfall documented and a `lus check` warning when such a table is cloned or used as an `__index` prototype in the same file.
- (c) Adopt nothing. Derived fields use a local before the constructor, and functions use `self`.

**Decision.** Lus adopts none of the forms. Derived fields use a local computed before the constructor, and functions that need their table use `self`.
