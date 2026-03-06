---
title: Lus 1.5.0
date: 03-06-2026
---

# 1.5.0

**A Visual Studio Code extension is now available.** It provides formatting, live diagnostics, and syntax highlighting for VSCode-based text editors, including VSCodium and Cursor. You can retrieve it from either the [VSCode marketplace](https://test.com) or the [Open VSX Registry](https://open-vsx.org). Those that use other LSP-capable text editors like Vim can take a look at the [language server](https://github.com/lus-lang/lus/tree/main/lus-language) for manual usage.

- Added string interpolation.
- Added `lus format` command.
- Added runtime attributes for altering local assignments.
- Added error-processing handlers to `catch` expressions.
- Added initial language server foundation and VSCode extension.
- Enum ordering comparison across different enum roots now raises a runtime error.
- Brought `debug.parse` to parity with the internal parser.
- Fixed `debug.parse` serializing linked lists as single nodes instead of arrays.
- Fixed buffer overflow in worker message serialization when arena allocation fails.
- Fixed missing recursion depth limit in worker message deserialization.
- Fixed integer overflow in `deser_read` bounds check that could allow out-of-bounds reads with large `size_t` values.
- Fixed negative or huge table counts in worker deserialization being passed to `lua_createtable` unchecked.
- Fixed missing `luaL_checkstack` in worker deserialization that could exhaust the Lus stack on deeply nested tables.
- Fixed uninitialized constant slots in enum parsing that could cause a GC crash when `luaM_growvector` expanded the constants array.
- Fixed missing bounds checking in bundle index parser.
- `adjustlocalvars` now validates the register limit before assignment.
