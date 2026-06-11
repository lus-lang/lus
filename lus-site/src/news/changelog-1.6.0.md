---
title: Lus 1.6.0
date: 2026-06-10
---

**Lus now installs itself.** On Linux and macOS, `curl -fsSL https://lus.dev/install.sh | sh` downloads the right binary, verifies it, and puts `lus` on your `PATH`; on Windows, [lus-setup.exe](https://github.com/lus-lang/lus/releases/latest/download/lus-setup.exe) does the same with a per-user installer. Release binaries are now self-contained — statically linked, runnable on a clean machine — and every release publishes a `SHA256SUMS` asset. Under the hood, this release also makes the VM substantially faster through intrinsified standard-library fastcalls.

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

