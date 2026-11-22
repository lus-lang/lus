# Hints of `lus check`

_Status: proposal for review. Nothing in this note is implemented yet. The open questions at the end each list choices with a recommendation._

A _hint_ is a diagnostic of `lus check` and the language server that suggests a faster or shorter form of correct code. Every hint in this note rests on a measured case in `tests/bench/hints/cases.lus`, which pairs the form a hint flags with the form it suggests. Both forms compute the same result. `lus -Pload -Pfs:read tests/bench/hints/run.lus` prints the best time of each form and their ratio.

The tables give the ratio of the flagged form's time to the suggested form's time, so 2.0 means the suggested form takes half as long. The numbers come from a ReleaseFast build on an Apple silicon Mac, as the best of five runs. "interpreter" is `LUS_JIT=off`, and "JIT" is the default setting with both tiers.

## 1. Proposed hints for speed

| code | flagged form | suggested form | interpreter | JIT |
| --- | --- | --- | ---: | ---: |
| `concat-in-loop` | `s = s .. x` in a loop, with `s` declared outside the loop | collect the parts in a list, then `table.concat` | 101 | 116 |
| `insert-front-in-loop` | `table.insert(t, 1, v)` in a loop | append, then reverse the list once | 8000 | 16000 |
| `closure-in-loop` | a function expression in a loop that captures no variable declared in the loop | declare the function before the loop | 2.3 | 18 |
| `select-in-loop` | `select(i, ...)` in a loop | `table.pack(...)` once, then index it | 1.7 | 2.0 |
| `table-to-group` | a table constructor assigned to a local that the function only reads and writes fields of | `<group>` on the local | 4.6 | 1.3 |
| `pairs-over-list` | `pairs(t)` where `t` is a list built in the same function | `ipairs(t)` | 1.4 | 1.3 |
| `format-to-interpolation` | `string.format` whose format holds only `%s` and literal text | a string with interpolation | 1.5 | 1.6 |
| `redundant-tostring` | `tostring(x)` as an operand of `..` where `x` is known to be a number | `x` itself | 2.5 | 2.6 |

The ratios of the first two hints grow with the length of the loop, because the flagged forms copy the whole string or list on every pass. The cases use 20000 passes.

Each hint fires only where the checker proves its condition from the source. `concat-in-loop` needs `s` to be a local of the enclosing function. `closure-in-loop` needs every variable the function reads to be declared outside the loop. `table-to-group` needs the local to stay inside the function: no call receives it, no return or table holds it, and no nested function captures it. `pairs-over-list` needs the table to come from a constructor with positional items only, or to be filled only by `t[#t + 1] = v`. `format-to-interpolation` excludes `%d` and the other conversions, because `%d` raises an error for `1.5` while interpolation writes it. `redundant-tostring` needs `x` to be a numeric `for` variable or the result of arithmetic, because `..` raises an error for a table or `nil` where `tostring` returns text.

## 2. Proposed hints for concise code

These hints suggest a shorter form that costs the same. They join the existing hints `use-from`, `use-optional-chain`, and `use-if-assign`.

| code | flagged form | suggested form | interpreter | JIT |
| --- | --- | --- | ---: | ---: |
| `use-interpolation` | a chain of three or more `..` operands mixing literals and values | a string with interpolation | 1.07 | 1.02 |
| `use-for-from` | a generic `for` whose body starts by copying fields of its only loop variable into locals of the same names, and uses the variable for nothing else | `for name, price from ...` | 0.99 | 1.00 |

## 3. Findings for the runtime

Three measured cases show the runtime, not the program, as the place to fix. A hint would teach programmers to avoid code that should be fast.

| case | slower form | faster form | interpreter | JIT |
| --- | --- | --- | ---: | ---: |
| `insert-append` | `table.insert(t, v)` | `t[#t + 1] = v` | 3.8 | 4.4 |
| `ipairs-vs-numeric` | `for _, v in ipairs(t)` | `for i = 1, #t do local v = t[i]` | 1.9 | 6.0 |
| `fields-vs-ctor-escape` | `{ x = i, y = i, z = i }` stored in a list | `{}` then three field stores | 1.4 | 1.3 |

The last row measures the constructor as the slower form: a table built by its constructor takes between 1.3 and 1.7 times as long as the same table built with three stores, over repeated runs, when every table stays alive in a list. The same constructor matches the stores when the table dies at once (`fields-one-by-one`, 1.03 and 1.02).

## 4. Candidates measured and left out

| case | flagged form | interpreter | JIT | reason |
| --- | --- | ---: | ---: | --- |
| `global-in-loop` | a global function called in a loop | 1.21 | 1.01 | the JIT removes the cost |
| `libfield-in-loop` | `math.abs` called in a loop | 1.28 | 1.05 | the JIT removes the cost |
| `nested-field-in-loop` | `obj.pos.x` read in a loop | 1.91 | 0.98 | the JIT removes the cost |
| `fields-one-by-one` | a table built by field stores where a constructor fits | 1.03 | 1.02 | no difference |
| `sub-char-loop-mixed` | `s:sub(i, i)` over every character | 0.64 | 0.58 | faster than `gmatch(".")`, because strings cache the position of a character index |

## 5. Open questions

**Q1. Which hints ship?**

- **(a) The eight speed hints and the two concise hints of sections 1 and 2 (recommended).**
- (b) The speed hints only.
- (c) Only the hints whose ratio exceeds 2 under the JIT: `concat-in-loop`, `insert-front-in-loop`, `closure-in-loop`, `select-in-loop`, and `redundant-tostring`.

**Q2. What happens to the three runtime findings of section 3?**

- **(a) They go to the speed workstream as runtime work, and no hint covers them (recommended).**
- (b) Hints cover them until the runtime is fixed, then the hints go.

**Q3. How do hints appear?**

- **(a) As a new severity, `hint`, which `lus check` prints and the language server shows as a hint, and which does not change the exit status (recommended).** Existing concise hints such as `use-from` move to this severity.
- (b) As warnings, like `use-from` today.

**Q4. Do hints that only help the interpreter ship?**

- **(a) No (recommended).** The JIT runs by default, so section 4's global and field reads cost nothing in a normal run.
- (b) Yes, behind an option for programs that run with `LUS_JIT=off` or on targets without a JIT.
