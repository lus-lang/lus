# Observed variables

_Status: implemented._

An _observed variable_ is a local declared with the `<observe>` attribute. An observed variable whose initializer reads other observed variables is a _derived_ variable, and the observed variables it reads are its _dependencies_. An observed variable with no observed dependency is a _source_. When a program assigns a source, from the declaring function or from any nested function, every derived variable that depends on it, directly or through other derived variables, is computed again from its initializer.

```lus nocheck
local z = 10
local a <observe> = 1
local b <observe> = 2
local c <observe> = z + a + b
b = 3
z = 20
assert(c == 14)
```

## 1. Semantics

### Recomputation at the assignment

`c` is 14 at the end, which is `10 + 1 + 3`. The assignment `b = 3` computes `c` again while `z` is still 10. The assignment `z = 20` changes nothing, because `z` is not observed. Recomputation therefore happens at the assignment, and a non-observed variable that an initializer reads is an input whose value is taken at the time of recomputation.

### Dependencies

The dependencies of a derived variable are the observed variables that its initializer names, found in the syntax tree as the compiler finds the variables a function captures. An observed variable read through a call, as in `local c <observe> = total()` where `total` reads `a`, is not a dependency. A dependency may be a local of the same function or a captured variable of an enclosing function.

A derived variable is read-only. An assignment to it raises `attempt to assign to const variable 'c'` at compile time, in the declaring function and in nested functions alike.

### Writes from nested functions

A nested function that assigns a source updates the dependents of that source, as an assignment in the declaring function does. This covers event handlers, callbacks passed to a library, and functions stored in tables.

```lus nocheck
local clicks <observe> = 0
local label <observe> = `clicked $clicks times`

button.on_click = function()
    clicks = clicks + 1   -- updates label
end
```

### Lifetime of a dependency

A derived variable depends on its sources from its declaration until the end of its scope. When its block ends, by reaching `end`, by `break`, `goto`, or `return`, or by an error, the derived variable stops depending on its sources, as a `<close>` variable is closed on every exit of its block. A source that outlives the block, because a nested function captured it, then no longer computes the dead variable. A nested function that captured the derived variable keeps reading its last value.

## 2. Update order

When a source changes, the runtime collects every derived variable that depends on it, directly or through other derived variables, and computes each one once, in the order of its declaration. A derived variable can depend only on variables declared before it, because its initializer cannot name a later local. Declaration order is therefore a topological order of the dependencies, and the dependencies never form a cycle.

The order holds across function activations, because the runtime numbers each derived variable when its declaration executes. In the diamond below, `a = 5` computes `b`, then `c`, then `d` once, and `d` never sees a new `b` with an old `c`.

```lus nocheck
local a <observe> = 1
local b <observe> = a * 2
local c <observe> = a + 1
local d <observe> = b + c
a = 5
assert(d == 16)
```

An initializer runs in the coroutine that made the assignment. An assignment to an observed variable while an update is running raises `cannot assign observed variable 'a' while its dependents update`, from any coroutine, because the update would otherwise read a source that changes under it.

An initializer may yield during an update. The update then pauses with the coroutine, and it resumes with the next dependent in declaration order when the coroutine resumes. While it is paused, the update still counts as running, so an assignment to an observed variable in any coroutine raises the error above. A reader in another coroutine sees the dependents that the paused update already computed with their new values and the others with their previous values. If the paused coroutine is closed, the update ends there: the dependents it did not reach keep their previous values, and observed variables accept assignments again.

If an initializer raises an error during an update, the error propagates from the assignment that started the update. The source keeps its new value. The derived variables computed before the error have their new values, and the failing variable and those after it keep their previous values.

## 3. Representation

The compiler resolves every name lexically, so it knows at each assignment whether the target is a source. Every decision below is made at compile time, which keeps code that never declares an observed variable exactly as it is today.

**Sources.** A source has a hidden companion local, `(observers x)`, its list of dependents. It holds `nil` until the first dependent registers, which stores a fresh list in it. An assignment to the source compiles to a call of the builtin `obscheck`, which raises when an update runs, then the store, then a test of the companion. When the companion holds a list, the assignment calls the builtin `obsrun` with it.

**Captured sources.** A nested function that assigns a source captures the companion along with the source, as one more upvalue, and its assignment compiles the same way. A nested function that only reads the source captures the source alone.

**Derived variables.** A derived variable compiles to a register or upvalue like any local, plus a list of its own, created at the declaration, and an update function that evaluates the initializer and stores the result in the variable. Executing the declaration evaluates the initializer, then calls the builtin `obsregister`, which numbers the update function with the next value of the state's declaration counter and adds a record of it to the list of each dependency. A to-be-closed guard calls `obsunregister` when the scope ends, which removes the record from those lists.

**Update.** `obsrun` collects the records of the list and, transitively, of the lists of the derived variables they update. It sorts them by their numbers, then calls each update function once in that order. It is written in Lus, so an initializer may yield, and a to-be-closed guard marks the end of the update however it ends: by finishing, by an error, or by the close of a paused coroutine. The builtins reach compiled code as constants that binary chunks store by number (`lazy.md`, section 7).

## 4. Cost

`tests/bench/observe.lus` measures the following, with a ReleaseFast build on an Apple silicon Mac.

| operation | cost |
| --- | --- |
| any code without observed variables | none, the compiler emits the same instructions as before |
| read of an observed variable | the same as a read of a local: 0.010 s for five million reads in both cases, interpreted |
| assignment to a source without dependents | the store and one call of `obscheck`: 0.057 s against 0.009 s for five million assignments, interpreted, and 0.046 s against 0.003 s under the JIT |
| assignment to a source with one dependent | about 300 ns, most of it the collection and sort in `obsrun` and the guard it creates |
| declaration of a derived variable | one evaluation of the initializer, the update function, a record, and a guard |

The call of `obscheck` keeps the decision of section 6 that any assignment during an update raises, including an assignment to a source without dependents. Observed variables belong in code that reacts to changes, such as the state of a user interface, rather than in hot loops.

## 5. Interaction with other features

- `<const>` and `<observe>` together are a compile error on a source, which could then never change. On a derived variable `<const>` adds nothing, because a derived variable is read-only.
- `<lazy>` and `<observe>` together are a compile error. A lazy variable computes at its first read and an observed one at each change, and the motivating example gives 14 with `<observe>` where a recomputation at read time would give 24.
- `<close>`, `<group>`, and runtime attributes on an observed variable are compile errors. A field of a local group cannot be observed.
- A global cannot be observed, because a global is a field of the global table and its assignments are table writes.
- `debug.setlocal` and `debug.setupvalue` store without an update, as they bypass every other attribute.
- An observed variable accepts only plain assignments. `x, y from t` and `function x() end` on an observed local are compile errors, `cannot assign observed variable 'x' with 'from'` and `cannot assign observed variable 'x' with a function statement`.
- An observed variable passed to a function passes its current value. The callee receives no link to the variable.

## 6. Decisions

- An error in an initializer during an update raises at the assignment, and the dependents not yet updated keep their previous values (section 2).
- An assignment to an observed variable during an update raises an error.
- An initializer may yield during an update, with the behavior of section 2.
