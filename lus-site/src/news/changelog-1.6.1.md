---
title: Lus 1.6.1
date: 2026-06-12
---

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
