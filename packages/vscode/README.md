# Lus

Language support for [Lus](https://github.com/lus-lang/lus), a small, fast, and productive language to build programs.

This extension provides completions, diagnostics, syntax highlighting, and formatting for `.lus` files. Each extension release carries its matching Lus WebAssembly runtime, language server, and standard library data.

The package runs in VS Code's Node-based workspace extension host. Remote workspaces run it in their remote workspace host, where it mirrors `.lus` and `.lua` files through the VS Code filesystem API for cross-file analysis. Browser-only extension-host packaging is planned for a future release.

The language client and server accept JSON-RPC frames up to 16 MiB. Oversized or malformed frames are rejected before dispatch.

## Debugging

The `lus` debug type runs a script under `lus debug`, the debug adapter built into the Lus 2.0 command line. It supports line breakpoints with conditions, hit counts, and log messages, stopping on uncaught or on every raised error, stepping, pausing, and inspecting locals, upvalues, globals, and tables. Expressions typed in the debug console or added as watches read the variables of the selected frame and cannot assign to them.

Pressing F5 in a `.lus` file debugs that file. A launch configuration takes `program`, `args`, `cwd`, `stopOnEntry`, and `pledges`. The `lus.executablePath` setting names the `lus` command, which defaults to the one on the `PATH`.

## Testing

The Testing view lists every `*_test.lus` file of the workspace with its top-level `NAME_test` and `NAME_bench` functions, and the editor shows a run button beside each one. A run starts `lus test --json` on the file, with `--filter` when it runs one test, and marks each test with its result. A failed test shows its message at the line of the assertion. A case of a table-driven test that fails marks the whole test as failed. **Run with Coverage** adds `--coverage-out` and colors the lines of the code under test that ran. The tests run with the `lus` command that `lus.executablePath` names.

## Links

- [Repository](https://github.com/lus-lang/lus)
- [Manual](https://lus.dev/manual/introduction/)
