# Observed variables

_Status: design for review. Nothing in this note is implemented yet. The open questions at the end each list choices with a recommendation._

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

An initializer runs in the coroutine that made the assignment. An assignment to an observed variable while an update is running raises `cannot assign observed variable 'a' while its dependents update`, because the update would otherwise read a source that changes under it. A yield inside an initializer during an update raises `attempt to yield inside an observed update`.

If an initializer raises an error during an update, the error propagates from the assignment that started the update. The source keeps its new value. The derived variables computed before the error have their new values, and the failing variable and those after it keep their previous values.

## 3. Representation

The compiler resolves every name lexically, so it knows at each assignment whether the target is a source. Every decision below is made at compile time, which keeps code that never declares an observed variable exactly as it is today.

**Sources.** A source has a hidden companion local, its _dependents list_, declared next to it. The list starts empty. An assignment to the source compiles to the store followed by a `notify` instruction on the companion. `notify` tests whether the list is empty and returns when it is.

**Captured sources.** A nested function that assigns a source captures the companion along with the source, as one more upvalue. Its assignment compiles to the store into the upvalue followed by `notify` on the captured companion. A nested function that only reads the source captures the source alone.

**Derived variables.** A derived variable compiles to a register or upvalue like any local, plus a hidden _update function_ that evaluates the initializer and stores the result in the variable. Executing the declaration evaluates the initializer, creates the update function, gives it the next number of the state's declaration counter, and adds it to the dependents list of each dependency. A derived variable that is itself a dependency has a dependents list of its own. Leaving the scope removes the update function from each list, through the same mechanism that closes `<close>` variables.

**Update.** `notify` on a non-empty list collects the update functions of the list and, transitively, of the lists of the derived variables they update. It sorts the collected functions by their numbers, removes duplicates, then calls each one in that order.

## 4. Cost

| operation | cost |
| --- | --- |
| any code without observed variables | none, the compiler emits the same instructions as today |
| read of an observed variable | a read of a local or an upvalue |
| assignment to a source without dependents | the store, then one test of an empty list |
| assignment to a source with dependents | the store, a collection and sort of the dependents, and one call of each update function |
| assignment to a source from a nested function | the same, plus one upvalue in that function for the companion |
| declaration of a derived variable | one evaluation of the initializer, one closure, and one list insertion per dependency |
| end of the scope of a derived variable | one list removal per dependency |

The JIT compiles `notify` as a call to a runtime routine behind the test of an empty list. Assignments to plain variables and plain upvalues compile unchanged in every tier, because `notify` exists only after assignments to sources.

## 5. Interaction with other features

- `<const>` and `<observe>` together are a compile error on a source, which could then never change. On a derived variable `<const>` adds nothing, because a derived variable is read-only.
- `<lazy>` and `<observe>` together are a compile error. A lazy variable computes at its first read and an observed one at each change, and the motivating example gives 14 with `<observe>` where a recomputation at read time would give 24.
- `<close>`, `<group>`, and runtime attributes on an observed variable are compile errors. A field of a local group cannot be observed.
- A global cannot be observed, because a global is a field of the global table and its assignments are table writes.
- `debug.setlocal` and `debug.setupvalue` store without `notify`, as they bypass every other attribute.
- An observed variable passed to a function passes its current value. The callee receives no link to the variable.

## 6. Open questions

**Q1. What happens when an initializer raises an error during an update?**

- **(a) The error propagates from the assignment, and the variables after the failing one keep their previous values (recommended).** The update stops where the error happened, like any sequence of statements.
- (b) The update computes every variable it can, skips the failing one and those that depend on it, then raises the first error.

**Q2. What happens when code assigns an observed variable while an update is running?**

- **(a) It raises an error (recommended).** An update never sees a source change under it.
- (b) The assignment is queued, and its update runs after the current one ends. A program that assigns on every update then loops forever.

**Q3. May an initializer yield during an update?**

- **(a) No, a yield raises an error (recommended).** An update ends before any other coroutine runs, so no coroutine sees half an update.
- (b) Yes. Another coroutine that assigns an observed variable during the yield raises the error of Q2.
