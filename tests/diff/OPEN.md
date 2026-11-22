# Open findings

This list holds the bugs and questions that the testing harnesses found and that are not fixed yet. Each entry names the harness, the smallest reproducer, and what is known. A fixed bug leaves this list and gains a regression test in `tests/conformance`.

## A string longer than 4 GiB panics

Harness: `tests/diff` (seed 6 of the generator with `<observe>`). Reproducer, which runs until a string passes 4 GiB:

```lus nocheck
local function f(p)
    repeat
        p = `<$(table.concat({ 48, 2147483647 }, string.format("%q|%10.3s", p, p)))>`
    until false
end
f(0)
```

`createStringAs` in `vm/state.zig` stores the length in 32 bits, so a longer string panics with `integer does not fit in destination type` where it should raise a memory error. It reproduces on `rewrite` before the language features of this branch. Each configuration of the runner allocates the string, so the seed also takes several gigabytes of memory per process.
