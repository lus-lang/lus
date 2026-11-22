# Observed variables

_Status: investigation. Nothing in this note is implemented or committed to. It ends with a verdict and choices._

An _observed variable_ is a proposed local declared with the `<observe>` attribute. An observed variable whose initializer reads other observed variables is a _derived_ variable. When a program assigns an observed variable, every derived variable that depends on it is computed again from its initializer. The motivating example follows.

```lus nocheck
local z = 10
local a <observe> = 1
local b <observe> = 2
local c <observe> = z + a + b
b = 3
z = 20
assert(c == 14)
```

## 1. What the example fixes

`c` is 14 at the end, which is `10 + 1 + 3`. The assignment `b = 3` computes `c` again, while `z` is still 10. The assignment `z = 20` changes nothing, because `z` is not observed. Two consequences follow.

- Recomputation is eager. It happens at the assignment to the observed variable. A design that marks `c` stale and computes it at its next read would read `z` as 20 and give 24.
- Only observed variables are dependencies. A derived variable records the observed variables its initializer reads, and every other variable it reads is an input whose value is taken at the time of recomputation.

## 2. Dependencies and update order

The dependencies of a derived variable are the observed variables that its initializer names. The compiler finds them in the syntax tree, as it finds the variables a function captures. An observed variable read through a function call, as in `local c <observe> = total()` where `total` reads `a`, is not a dependency. A design that tracks reads at run time would catch it, at the cost described in section 5.

A derived variable can depend only on variables declared before it, since its initializer cannot name a later local. Declaration order is therefore a topological order of the dependency graph, and the graph has no cycles. When an assignment changes a variable, the compiler recomputes its dependents in declaration order, each once. In the diamond below, `a = 5` computes `b`, then `c`, then `d` once, and `d` never sees a new `b` with an old `c`.

```lus nocheck
local a <observe> = 1
local b <observe> = a * 2
local c <observe> = a + 1
local d <observe> = b + c
a = 5
assert(d == 16)
```

An assignment to a derived variable would replace a value that the next change of a dependency overwrites, and could hide the dependency entirely. Derived variables are therefore read-only, and an assignment to one is a compile error. Only observed variables without observed reads in their initializer, the _sources_, accept assignments. Cycles cannot form, because no assignment makes a source depend on anything.

## 3. Captured variables

A function that reads an observed variable reads it as an ordinary captured variable, so it sees the value of the last recomputation.

An assignment to a source inside a nested function is the difficult case. The function may run after a derived variable that it cannot name has been declared, so the compiler of that function cannot know which dependents to recompute. Two designs work.

- The rule of runtime attributes. An assignment in a nested function stores the value and triggers nothing, as an assignment to a variable with a runtime attribute calls no attribute there (`guide.mdx`, "Rules for runtime attributes"). This keeps the compiler static, but it makes `c` silently stale after a callback assigns `b`.
- A compile error for an assignment to a source from a nested function. The rule is static and leaves nothing stale, but it rules out callbacks, which are the main producers of changes in event-driven code.

A design that propagates from nested functions needs each source to live in a heap cell that holds the list of its dependents, with each derived variable compiled as a hidden function. That is a library of signals with a syntax of its own (section 5).

## 4. Cost

With the static design, a read of an observed variable is a read of a local. An assignment to a source compiles to the store followed by the initializer of each dependent, inlined at the assignment in declaration order. The cost of an assignment is the sum of the cost of those initializers, and the code of a function grows with the number of assignments times the number of dependents. Compiling each initializer once, as a hidden function that each assignment calls, bounds the code size at the cost of a call per dependent.

A program that declares no observed variable compiles and runs exactly as before.

## 5. Locals or a library of signals

A _signal_ library keeps reactive values in objects: `signal(1)` holds a value, `computed(fn)` derives one, and `effect(fn)` runs a function when its inputs change. The library tracks dependencies at run time by recording which signals a computation reads, so dependencies through calls, across functions, and across modules all work. It can batch several changes into one recomputation, and it can dispose of a computation that is no longer needed.

The uses that motivate reactivity cross function boundaries: a user interface that redraws when its state changes, a cache that drops entries when its source changes, and a configuration that reloads. The changes arrive in callbacks, and the reactions are effects with side effects. Observed locals cover the part of this that fits in one function and has no callbacks, which is the part a program can already write as a sequence of assignments.

A library costs a table and a closure per signal, and a call and a dependency check per read and per write, against nothing for the static locals. A library needs no change to the language and can ship as a package, while observed locals need a new attribute, a compile-time dependency analysis, and rules for nested functions.

## 6. Relation to `<lazy>`

A lazy variable is computed once, at its first read, and pulls its value (`lazy.md`). An observed variable is computed again at every change of a dependency, and its sources push changes to it. The combination `<lazy, observe>` would mark a derived variable stale at a change and compute it at its next read. That reads every non-observed input at read time, so in the motivating example it gives 24 where `<observe>` gives 14. The two attributes are therefore different features and do not reduce to each other.

## 7. Verdict

Observed locals are implementable at no cost for programs that leave them unused, with static dependencies, declaration order as update order, and no cycles. The uses that justify reactivity need propagation from callbacks and dependencies through calls, which static locals cannot give without becoming a signal library with special syntax.

**Choices**

- **(a) Leave `<observe>` out of the language and publish signals as an atmosphere package, with `signal`, `computed`, and `effect` over table fields and run-time dependency tracking (recommended).**
- (b) Adopt static observed locals with the rule of runtime attributes for nested functions, and read-only derived variables.
- (c) Adopt static observed locals and make an assignment to a source from a nested function a compile error.
- (d) Adopt nothing.
