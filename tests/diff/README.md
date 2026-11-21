# Differential tests

The scripts in this directory generate random Lus programs, run each one under every configuration of the runtime, and report every crash and every difference between configurations (`spec/design/testing.md`). No program has an expected output. The interpreter's output is the reference, and every JIT tier, the gc-stress build, and `lus fmt` must print the same. The x86-64 and WebAssembly builds each compare with their own interpreter.

The generator, the runner, and the reducer are written in Lus and run interpreted with `LUS_JIT=off`. The generator writes each program to a file, and every configuration runs that file in a fresh process, so a bug of the runtime under test cannot change what the generator made or how the runner judges it. `wasm.mjs` is the one script in JavaScript, since the WebAssembly build runs in Node.

- `gen.lus` builds a program from a seed. `lus gen.lus SEED` prints it.
- `run.lus` runs a batch of seeds and writes each finding to `findings/` as the program, a report, and with `--reduce` a reduced program.
- `reduce.lus` shrinks any Lus file while a crash or a difference stays.
- `lib.lus` holds the configurations and the comparison that the other two share.

Run 200 programs under the configurations of the native binary with the following command, from the repository root.

```sh
LUS_JIT=off runtime/zig-out/bin/lus tests/diff/run.lus --count 200 --start 1
```

The long run adds the gc-stress, x86-64, and WebAssembly builds, picks fresh seeds, and runs until stopped.

```sh
LUS_JIT=off runtime/zig-out/bin/lus tests/diff/run.lus --forever --reduce --jobs 8 \
    --stress runtime/zig-out-stress/bin/lus --x64 runtime/zig-out-x64/bin/lus --wasm packages/wasm/dist/lus.wasm
```

Reduce a program that crashes under one configuration, or that differs between two, with `reduce.lus`.

```sh
LUS_JIT=off runtime/zig-out/bin/lus tests/diff/reduce.lus findings/seed123.lus --mismatch off,opt-eager
LUS_JIT=off runtime/zig-out/bin/lus tests/diff/reduce.lus findings/seed123.lus --crash eager
```

A finding that is fixed gets a regression test in `tests/conformance`. A finding left open goes into `OPEN.md`.
