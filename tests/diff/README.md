# Differential tests

The scripts in this directory generate random Lus programs, run each one under every configuration of the runtime, and report every crash and every difference between configurations (`spec/design/testing.md`). No program has an expected output. The interpreter's output is the reference, and every JIT tier, the gc-stress build, and the x86-64 build must print the same.

`gen.mjs` builds a program from a seed. `run.mjs` runs a batch of seeds and writes each finding to `findings/` as the program, the outputs, and with `--reduce` a reduced program. `reduce.mjs` shrinks any Lus file while a crash or a difference stays.

Run 200 programs under the configurations of the native binary with the following command, from the repository root.

```sh
node tests/diff/run.mjs --count 200 --start 1
```

The long run adds the gc-stress build and the x86-64 build, picks fresh seeds, and runs until stopped.

```sh
node tests/diff/run.mjs --forever --reduce --stress runtime/zig-out-stress/bin/lus --x64 runtime/zig-out-x64/bin/lus
```

Reduce a program that crashes under one configuration, or that differs between two, with `reduce.mjs`.

```sh
node tests/diff/reduce.mjs findings/seed123.lus --mismatch off,opt-eager
node tests/diff/reduce.mjs findings/seed123.lus --crash eager
```

A finding that is fixed gets a regression test in `tests/conformance/diff_regress_test.lus`. A finding left open goes into `OPEN.md` with its reproducer under `open/`.
