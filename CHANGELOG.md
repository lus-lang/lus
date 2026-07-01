# Changelog

## 1.6.2

**Release date:** July 1, 2026

- Fixed sealed code being able to `load` unverified precompiled bytecode.
- Fixed a read-only `fs:write` permission check being able to insert an entry into a sealed pledge store.
- Fixed `network.udp` sockets being able to `sendto` any host and port regardless of the granted `network:udp`.
- Fixed a use-after-free in which abandoned worker-pool threads could read a parent state's freed pledge store during interpreter shutdown.
- Fixed `fs.createlink` pledge-checking only the link path and not the symlink target.
- Fixed an unanchored `fs` pledge pattern beginning with a wildcard matching files anywhere on the filesystem.
- Fixed `catch` leaking the interpreter's C-call counter when a caught error unwound across a C-call boundary.
- Fixed a table slice with an enormous end index iterating for trillions of steps instead of failing.
- Fixed `vector.unpack` and `vector.unpackmany` reading past the end of a vector when unpacking an unterminated `z` string.
- Fixed `network.udp.open(port, address)` not enforcing value-scoped `network:udp` pledges for bound sockets.
- Fixed `network.fetch` truncating large HTTP request body lengths and send sizes through `int` casts.
- Fixed `network.fetch` accepting malformed or out-of-range URL ports.
- Fixed a stale `expdesc` initializer that caused a compiler warning after AST support was added.
- Fixed `network.udp` sockets being able to bind with `setsockname` outside their value-scoped `network:udp` pledge.
- Fixed `network:*` pledge values containing `host:port` never matching checks that included a port.
- Fixed TCP and UDP socket APIs truncating out-of-range ports before binding, connecting, or sending.
- Fixed `fromjson` accepting out-of-range integers and infinities instead of rejecting those numeric literals.
- Fixed `fromjson` direct table writes so they perform the required GC write barrier.
- Fixed `fromcsv` accepting junk after a quoted field and reinterpreting it as later CSV structure.
- Fixed TCP socket `send` chunking so large writes are never narrowed through an oversized `int`.
- Fixed gzip and deflate compression rejecting inputs and output bounds too large for zlib's single-shot `uInt` fields.
- Fixed `vector.unpackmany` accepting negative offsets or counts as empty iterators.
- Fixed numeric CLI options such as `format --indent` and `--gc-pause` accepting trailing garbage.
- Fixed sealed `require` calls being able to load precompiled bytecode modules through `package.path`.
- Fixed sealed workers being able to load precompiled bytecode scripts after inheriting parent pledges.
- Fixed `network.fetch` accepting CA-trusted HTTPS certificates without verifying the requested hostname.
- Fixed `network.fetch` allowing carriage-return or line-feed characters in URL paths to reach the HTTP request line.
- Fixed gzip and deflate decompression looping forever on truncated no-progress input.
- Fixed `package.searchpath` probing file existence before checking value-scoped `fs:read` pledges.
- Fixed LZ4 and unknown-size zstd decompression accepting truncated frames as successful partial output.
- Fixed vector-returning archive compression and zstd decompression paths copying from closed `luaL_Buffer` storage.
- Fixed path-scoped `fs:write` pledges allowing pathless temp-file creation through `io.tmpfile` and `os.tmpname`.
- Fixed command-line `-P`/`--pledge` restrictions being applied only after `LUA_INIT`, `-e`, and `-l` code could run.
- Fixed `fromjson` accepting invalid object-key escapes and raw control characters, and rooted parsed strings across GC-capable table insertion.
- Fixed vector and enum construction windows where partially initialized or unrooted GC objects could be collected during emergency allocation.
- Fixed `network.fetch` response parsing for invalid or oversized lengths, truncated bodies, missing chunk terminators, and blocking read/write timeouts.
- Fixed `vector.pack`, `vector.unpack`, and `vector.unpackmany` bounds checks that could wrap on very large `cN` format sizes.
- Fixed `lus_revokepledge` turning scoped grants into global grants in the public C API.
- Fixed worker error paths double-unlocking the worker mutex after signaling waiting receivers.
- Removed a stale unused `vector.unpackmany` iterator-state typedef.

## 1.6.1

**Release date:** June 12, 2026

- `network.fetch` now rejects carriage-return and line-feed characters in the HTTP method and in custom header keys and values, preventing header injection and request smuggling.
- Fixed an out-of-bounds read in `vector.archive` gzip and deflate decompression that could append uninitialized memory to the output when decompressing inputs larger than 1 GB.
- Fixed a worker thread leaving its mutex locked after an error — including a worker script that fails to load or raises at runtime — which could deadlock a parent waiting on it.
- Fixed running out of memory while growing the call stack being thrown from inside the garbage collector instead of being handled gracefully.
- Fixed a memory leak in the JSON parser when decoding a malformed object key (such as one missing its `:`).
- Fixed a memory leak in the worker library when a message could not be enqueued under memory pressure.
- Fixed `fs.path.join` orphaning an internal buffer when a later path component is absolute.
- Fixed a possible capacity overflow when growing a socket's receive buffer.
- Added a `NULL` guard to the `lus_worker_send` C API.
- The WASM language server no longer writes debug output to stderr on every document change.

## 1.6.0

**Release date:** June 10, 2026

- Added `fromcsv` and `tocsv` to parse CSV files.
- Added VM-intrinsified fastcalls for common standard library functions, reducing call overhead by ~31% (1.46x geometric mean speedup across 57 benchmarks).
  - When the compiler detects a call to a known stdlib function with the expected argument count, it emits `OP_FASTCALL` instead of `OP_CALL`. The VM validates at runtime that the function hasn't been replaced and executes the operation inline, falling back to a normal call otherwise.
  - Fastcall emission can be disabled by passing `--no-fastcall` to `lus`.
- Added `--readonly-env` flag that freezes `_ENV` and all module tables after initialization, enabling fast-dispatch fastcalls that skip runtime validation.
- Added `--gc-pause N` flag to bound how far the heap may grow past the live set before a new GC cycle starts in incremental mode.
- Added `--strip-debug` flag that drops debug information from every loaded chunk to save memory (~15% of loaded-code memory on small chunks, more on line-heavy files)
- Regular long strings no longer store a redundant content pointer, saving 8 bytes per long string.
- The string table now grows at a 1.5 load factor instead of 1.0, shrinking its bucket array by up to a third for string-heavy programs.
- `for ... in pairs(t)`/`ipairs(t)`/`next, t` loops over tables now walk the table directly in the VM instead of calling the iterator function each step (pairs ~1.8x, ipairs ~2.3x faster).
- Indexing tables with string variables (`t[k]`) now takes the same short-string fast path as constant fields, ~15% faster.
- Integer-to-string conversion uses a direct conversion loop instead of `snprintf` (~20% faster interpolation-heavy code).
- Release binaries for Linux and macOS are now built with profile-guided optimization (`tools/pgo-build.sh`), 15–45% faster across VM micro-benchmarks than a plain release build.
- The worker library no longer pre-allocates a table from an untrusted declared size while deserializing messages.
- Workers now inherit their parent's pledges (sealed).
- `fs` permission checks now canonicalize paths and fail closed.
- `network:http`/`network:tcp` permission checks now match the URL/host structurally, so a pledge for `example.com` no longer also permits `example.com.net`.
- Passing any `-P`/`--pledge` permission now seals the pledge store after startup.
- Replaced the short-string hash with a full-content hash.
- Fixed `network.tcp.bind` not checking `network:tcp` permission.
- Fixed `fs.createdirectory` and `fs.createlink` not checking `fs:write` permission.
- Fixed `fs.type` and `fs.follow` not checking `fs:read` permission.
- Fixed JSON parser not handling `\b`, `\f`, `\/`, and `\uXXXX` escape sequences in object keys.
- Fixed `msgqueue_push` crashing on allocation failure in the worker library.
- Fixed nested `catch` blocks in the same function corrupting control flow on a subsequent error.
- Fixed `catch` not closing to-be-closed variables when catching an error, which corrupted state when catching errors raised by standard-library functions that build internal buffers.
- Fixed slice expressions not validating that their bounds are integers.
- Fixed slicing an inline table constructor (e.g. `({1,2,3})[a,b]`) producing the wrong result.
- Fixed `table.clone(t, true)` crashing on deeply nested tables.
- Fixed `debug.parse` leaving the garbage collector permanently disabled if it ran out of memory while building its result.
- Fixed an intermittent `attempt to modify a readonly table` error caused by a value collision between the readonly-table flag and the table pre-set hash-node encoding.
- Fixed a buffer overflow in the Windows path canonicalizer on over-long paths.
- Gated the `io` library (`io.open`, `io.lines`, `io.input`, `io.output`, `io.tmpfile`) behind `fs:read`/`fs:write` pledges.
- Gated native module loading (`package.loadlib` and `require` of C modules) behind the `load` and `fs:read` pledges.
- Gated `os.getenv` behind a new `env` pledge and `os.tmpname` behind `fs:write`.
- Backport upstream Lua 5.5 fixes:
  - https://github.com/lua/lua/commit/3360710bd3ea8da06fa5062f9d10c2719083097c
  - https://github.com/lua/lua/commit/b60e2bcd7ca4c349bd6ee7a8e929f55e04f7ca87
  - https://github.com/lua/lua/commit/10eb89d1141dc528806b32401e408e36fb2f3bf5
  - https://github.com/lua/lua/commit/36d5d2b2847906aa3b66e020d5d894a14ba2bf90
  - https://github.com/lua/lua/commit/377cbea61b2688b21c7d243fc0f42498851df794
  - https://github.com/lua/lua/commit/51269bd783c9371252947b26cc865239dbb0153d
  - https://github.com/lua/lua/commit/f1bb2773bba8b16f0f01c00e59a7be541ef88cb7
  - https://github.com/lua/lua/commit/efddc2309c5ff8a1842bea8a9c0d7d4a5d6e1e60
  - https://github.com/lua/lua/commit/c037162a1a657088d722f550e287015525bb2259
  - https://github.com/lua/lua/commit/29cf284089d543408d726440a3f1acaecdf73636
  - https://github.com/lua/lua/commit/d0bd25d2e7fb393a6d0a73645a099f9c3b9cc0a8
  - https://github.com/lua/lua/commit/3228a97c6a953dcf397944161bb64b12f1ff5384
  - https://github.com/lua/lua/commit/4c5d5063a54c0088729b16fb25a333f0f9f836b0
  - https://github.com/lua/lua/commit/ae23e726018bd31a25c1279600328d90207ec81c
  - https://github.com/lua/lua/commit/0da6d320f757bc9241a33df06f3597598845cf0a
  - https://github.com/lua/lua/commit/36c1f6d949a4d3dfcbe898d80b1be1efe8e5325c
  - https://github.com/lua/lua/commit/53b41d0cddd80bf33fdc631bdd32e3ba53842b89

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
- Added `table.compact` (and C API `lua_compacttable`) to shrink a table's internal storage to fit its current contents.

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
