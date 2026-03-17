# Changelog

## 1.6.0 (**WIP**)

**Release date:** TBD

- Added `fromcsv` and `tocsv` to parse CSV files.
- Added VM-intrinsified fastcalls for common standard library functions, reducing call overhead by ~31% (1.46x geometric mean speedup across 57 benchmarks). When the compiler detects a call to a known stdlib function with the expected argument count, it emits `OP_FASTCALL` instead of `OP_CALL`. The VM validates at runtime that the function hasn't been replaced and executes the operation inline, falling back to a normal call otherwise.
  - Biggest individual gains are `table.sum` (4.60x), `string.join` (3.93x), `table.stdev` (2.35x), `tostring` (2.12x), and `table.mean` (1.97x).
  - `type`, `rawlen`, `rawget`, `rawset`, `rawequal`, `assert`, `getmetatable`, `setmetatable`, `tonumber`, `tostring`, `math.abs`, `math.max`, `math.min`, `math.ceil`, `math.floor`, `math.sqrt`, `math.sin`, `math.cos`, `math.tan`, `math.asin`, `math.acos`, `math.atan`, `math.exp`, `math.log`, `math.deg`, `math.rad`, `math.fmod`, `math.ult`, `math.tointeger`, `math.type`, `math.ldexp`, `string.len`, `string.sub`, `string.byte`, `string.char`, `string.lower`, `string.upper`, `string.reverse`, `string.trim`, `string.ltrim`, `string.rtrim`, `string.split`, `string.join`, `table.sum`, `table.mean`, `table.median`, `table.stdev`, `table.transpose`, `table.reshape`, `vector.create`, `vector.clone`, `vector.size`, `vector.resize`, `utf8.len`, `utf8.codepoint`, `utf8.char` and `utf8.offset` have supported fastcalls.
  - Fastcall emission can be disabled by passing `--no-fastcall` to `lus`.
- Added `--readonly-env` flag that freezes `_ENV` and all module tables after initialization, enabling fast-dispatch fastcalls that skip runtime validation.
- Fixed `network.tcp.bind` not checking `network:tcp` permission.
- Fixed `fs.createdirectory` and `fs.createlink` not checking `fs:write` permission.
- Fixed `fs.type` and `fs.follow` not checking `fs:read` permission.
- Fixed JSON parser not handling `\b`, `\f`, `\/`, and `\uXXXX` escape sequences in object keys.
- Fixed `msgqueue_push` crashing on allocation failure in the worker library.

### `table`

- Added `table.sum` to compute the sum of numeric values.
- Added `table.mean` to compute the arithmetic mean.
- Added `table.median` to compute the median.
- Added `table.stdev` to compute the standard deviation.
- Added `table.map` to apply a function to each element.
- Added `table.filter` to select elements by predicate.
- Added `table.reduce` to fold a table into a single value.
- Added `table.groupby` to group elements by a key function.
- Added `table.sortby` to sort in-place by a key function.
- Added `table.zip` to combine tables element-wise into tuples.
- Added `table.unzip` to split tuples into separate tables.
- Added `table.transpose` to transpose a 2D matrix.
- Added `table.reshape` to reshape a 1D array into a matrix.

### `string`

- Added `string.split` to split a string on a delimiter.
- Added `string.join` to join table elements with a delimiter.
- Added `string.trim` to remove leading and trailing characters.
- Added `string.ltrim` to remove leading characters.
- Added `string.rtrim` to remove trailing characters.

### `vector`

- Added `vector.archive.gzip.compress` and `vector.archive.gzip.decompress` for gzip compression.
- Added `vector.archive.deflate.compress` and `vector.archive.deflate.decompress` for raw deflate compression.
- Added `vector.archive.zstd.compress` and `vector.archive.zstd.decompress` for Zstandard compression.
- Added `vector.archive.brotli.compress` and `vector.archive.brotli.decompress` for Brotli compression.
- Added `vector.archive.lz4.compress`, `vector.archive.lz4.decompress`, and `vector.archive.lz4.decompress_hc` for LZ4 compression.

## 1.5.1

**Release date:** March 6, 2026

- Fixed WASM build targeting.

## 1.5.0

**Release date:** March 6, 2026

- Added string interpolation.
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
- Fixed missing `luaL_checkstack` in worker deserialization that could exhaust the Lua stack on deeply nested tables.
- Fixed uninitialized constant slots in enum parsing that could cause a GC crash when `luaM_growvector` expanded the constants array.
- Fixed race condition in worker receive context signaling that could cause a use-after-free when `lib_receive` destroys a stack-allocated context while a worker thread is still accessing it.
- Fixed missing bounds checking in bundle index parser.
- `adjustlocalvars` now validates the register limit before assignment.

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
