# Changelog

## 1.5.0 (**WIP**)

**Release date:** TBA

### Lus runtime

- Added string interpolation.
- Added runtime attributes for altering local assignments.
- Added error-processing handlers to `catch` expressions.
- Brought `debug.parse` to parity with the internal parser.
- Fixed `debug.parse` serializing linked lists (names, values, args, etc.) as single nodes instead of arrays.

### Lus language server

- Added initial language server foundation (JSON-RPC transport, LSP lifecycle, document sync).
- Added syntax diagnostics and document symbol outline to the language server.
- Added code formatting to the language server.
- Added scope analysis with variable declaration tracking and name resolution.
- Added semantic token highlighting (variables, parameters, functions, literals, comments).
- Added go-to-definition, find-references, hover, and rename support.
- Added cross-file analysis: `require()` resolution, module export extraction, and cross-file go-to-definition.
- Added documentation comment extraction in hover info.
- Added auto-completion for variables, globals, keywords, and stdlib members (all libraries including vector, fs, network, worker).
- Added signature help with parameter hints for all stdlib functions and user-defined functions.
- Added type inference for variables (number, string, boolean, table, function, vector, enum, thread, module) with table field tracking from constructors and assignments.
- Added Lua 5.5 interop: `debug.parse` handles `.lua` files natively for cross-file resolution.
- Added code folding for functions, control flow, tables, and comment blocks.
- Added inlay hints for parameter names at call sites and inferred types on declarations.
- Added workspace-wide symbol search with fuzzy matching.
- Added linting: unused variable warnings and undefined global detection.

### VS Code extension

- Bootstrapped the `lus-vscode` extension with WASM-first architecture.
- Added TextMate grammar and language configuration for `.lus` files.
- Added WASM API for LSP message handling (`lus_load_lsp`, `lus_handle_message`).
- Added non-blocking LSP entry point (`wasm.lus`) for WASM environments.
- Added custom LSP message transport over WASM for the VS Code language client.

## 1.4.0

**Release date:** February 2, 2026

- **Completed phase-out of function-level protected execution.**
  - For software embedding Lus and _only_ making use of the front-facing C APIs like `lua_pcall`, this should _not_ impact you as the functions have been retrofit with compatibility layers interfacing with the new catch system.
- Added `--standalone` to generate standalone binaries.
- Added local groups for grouping stack-allocated variables.
- Added `vector` type and library for buffers.
- Added slices for strings, tables, and vectors.
- Added `table.clone(t, deep?)` to create copies of tables.
- Added `catch[handler] expr` syntax to allow expression-level `xpcall`-like functionality.
- `from` deconstruction can now be done in `if`/`while` assignments.
- Refactored actions workflow.
- Various runtime optimizations:
  - Constant-time O(1) string hashing using sparse ARX algorithm.
  - Aligned string comparison for faster ordering.
  - Alias-aware table loops for improved compiler optimization.
  - O(1) catch handler lookup via `activeCatch` pointer.
  - Cold path extraction for trap handling and catch error recovery.
  - Arena-aware allocations where performance can be reliably improved.
  - Moved slice logic out of the VM and into its own `luaV_slice` function.
- Fixed our Windows builder, meaning Windows support has _finally_ returned.
- Fixed race condition in `worker.receive` that could cause lost wakeups.
- Fixed attribute usage in if-assignments and while-assignments.
- Fixed deeply nested JSON encoding/decoding crashing.

## 1.3.0

**Release date:** January 16, 2026

- Added scoped assignments in `while` loops.
- OpenBSD-inspired `pledge` mechanism to declare and restrict permissions.
- Added `string.transcode` for converting between encodings.
- Added `network.fetch`, `network.tcp`, and `network.udp`.
- Added `debug.parse` to generate ASTs from Lus code.
- Added `worker` library for concurrency.
- Backport Lua 5.5 RC3 and stable fixes:
  - https://github.com/lua/lua/commit/8164d09338d06ecd89bd654e4ff5379f040eba71
  - https://github.com/lua/lua/commit/104b0fc7008b1f6b7d818985fbbad05cd37ee654
  - https://github.com/lua/lua/commit/3d03ae5bd6314f27c8635e06ec363150c2c19062
  - https://github.com/lua/lua/commit/a5522f06d2679b8f18534fd6a9968f7eb539dc31
  - https://github.com/lua/lua/commit/578ae5745cecee56d48795cd4ae1eaf13618715c
  - https://github.com/lua/lua/commit/632a71b24d8661228a726deb5e1698e9638f96d8
  - https://github.com/lua/lua/commit/962f444a755882ecfc24ca7e96ffe193d64ed12d
  - https://github.com/lua/lua/commit/45c7ae5b1b05069543fe1710454c651350bc1c42
  - https://github.com/lua/lua/commit/5cfc725a8b61a6f96c7324f60ac26739315095ba
  - https://github.com/lua/lua/commit/2a7cf4f319fc276f4554a8f6364e6b1ba4eb2ded

## 1.2.0

**Release date:** December 6, 2025

- Added `fs` library for operating around the file system.
- Removed `os.rename` in favor of `fs.move`.
- Removed `os.remove` in favor of `fs.remove`.
- Fixed incorrect version strings.
- Fixed H3 test harness not running.
- Fixed `catch` erroring when parsed as a statement.
- H1 JSON test now includes the RFC8259 dataset.
- H1 JSON test now makes use of `fs` library.

## 1.1.0

**Release date:** December 6, 2025

- Added `tojson` and `fromjson` functions for JSON serialization and deserialization.

## 1.0.0

**Release date:** December 5, 2025

> [!NOTE]
> This changelog denotes differences between Lus and Lua 5.5 RC 2. Lua 5.5 most (in)famously introduces the `global` assignment statement; it is not a Lus-specific feature.

- Added table deconstruction with `from` assignment.
- Added scoped assignments in `if`/`elseif` conditionals.
- Added `catch` expression for error handling in expressions.
- Added optional chaining with the `?` suffix operator.
- Added first-class enums with the `enum` keyword.
- Added `os.platform` function that returns the platform name.
- Added support for WebAssembly builds.
- Added pre-built test suites in four harnesses.
- Removed `pcall` and `xpcall` in favor of `catch`.
- Upgraded the build system from `make` to `meson`.
