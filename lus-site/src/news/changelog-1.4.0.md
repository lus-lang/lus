---
title: Lus 1.4.0
date: 02-02-2026
---

# 1.4.0

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
