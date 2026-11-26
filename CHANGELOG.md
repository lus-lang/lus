# Changelog

## 2.0.0 (**WIP**)

**Release date:** TBD

Lus 2.0 is a new runtime with a compiler to machine code, a new garbage collector, a new embedding interface, and a set of tools in the `lus` command.

### Language

- Added the [`continue`](/manual/guide#break-and-continue) statement, which starts the next iteration of the innermost loop and makes `continue` a reserved word.
- Added [bigint and decimal numbers](/manual/guide#numbers) as subtypes of `number`, written with the literal suffixes `n` and `d`.
  - `bigint`: Converts a value to an arbitrary precision integer.
  - `decimal`: Converts a value to an exact base 10 number.
  - `math.type`: Reports `"bigint"` and `"decimal"` for the new subtypes.
  - `fromjson`: Decodes wide integers as bigints and fractional numbers as decimals when its [`exact`](/manual/data#parsing) option is `true`.
- Added [queries](/manual/guide#queries), which the `@` expression builds from clauses such as `where`, `select`, `group by`, and `order by` and which run over tables or an SQLite database.
  - `query`: Returns an iterator over the records of a query.
  - `debug.queryplan`: Describes how a query would run, as a string.
- Added [`for` loops with `from`](/manual/guide#destructuring-each-item-with-from), which copy the named fields of each item into local variables.
- Added the `<lazy>`, `<observe>`, `<context>`, and `<meta>` variable attributes.
  - [`<lazy>`](/manual/guide#values-computed-on-first-use): Computes the value at the first read of the variable.
  - [`<observe>`](/manual/guide#values-that-follow-other-values): Computes the value again whenever an observed variable that its initializer names is assigned.
  - [`<context>`](/manual/guide#values-for-each-coroutine): Gives the variable a value for each coroutine.
  - [`<meta>`](/manual/guide#values-computed-when-the-file-is-compiled): Runs the initializer when the file is compiled.
- Added [build flags](/manual/guide#build-flags), which the `-F` option defines and a program reads from the read-only `flags` table.
- Added [detached coroutines](/manual/concurrency#detached-coroutines), which the runtime resumes whenever the operation they wait for is ready.
  - `coroutine.detach`: Hands a suspended coroutine to the runtime and returns it.
  - `coroutine.sleep`: Returns a coroutine whose resume waits for a number of seconds.
- Added [remote modules](/manual/guide#modules-from-the-network), which `require` loads from a URL and keeps in a cache.
- Added the [`time`](/manual/time) library.
  - `time.now`: Returns an instant for the current time of the wall clock.
  - `time.monotonic`: Returns an instant of a monotonic clock, for measuring elapsed time.
  - `time.instant`: Returns an instant for a count of Unix seconds.
  - `time.duration`: Returns a duration that is the sum of the units in a table.
  - `time.days`, `time.hours`, `time.minutes`, `time.seconds`, and `time.millis`: Return a duration of one unit.
  - `time.zone`: Returns the zone with an IANA name such as `"Europe/Paris"`.
  - `time.offset`: Returns a zone with a fixed offset from UTC.
  - `time.localzone`: Returns the time zone of the system.
  - `time.zoned`: Returns a civil date and time in a zone.
  - `time.parse`: Reads an instant or a zoned time from ISO 8601 text or from an explicit pattern.
  - `time.weekday` and `time.month`: Enumerate the days of the week and the months of the year.
  - `time.tzdata_version`: Returns the release of the IANA time zone database that the runtime embeds.
- Added the [`crypto`](/manual/crypto) library.
  - `crypto.hash`: Returns the digest of data under a hash function.
  - `crypto.hasher`: Returns an object that computes a digest over data added in pieces.
  - `crypto.hmac`: Returns the HMAC of data under a key.
  - `crypto.equal`: Compares two byte sequences in time that depends only on their lengths.
  - `crypto.keypair`: Returns a new secret key and its public key.
  - `crypto.importkey`: Reads an RSA, EC, or Ed25519 key.
  - `crypto.sign`: Returns the signature of a message under a secret key.
  - `crypto.verify`: Checks the signature of a message against a public key.
  - `crypto.pbkdf2`: Derives a key from a password with PBKDF2.
  - `crypto.hkdf`: Derives bytes from a key with HKDF.
  - `crypto.encrypt`: Encrypts and authenticates a plaintext with AES-256-GCM.
  - `crypto.decrypt`: Checks and decrypts a ciphertext of `crypto.encrypt`.
  - `crypto.hashpassword`: Hashes a password with Argon2id.
  - `crypto.verifypassword`: Checks a password against a hash of `crypto.hashpassword`.
  - `crypto.random`: Returns bytes from the secure random source of the operating system.
  - `crypto.uuid`: Returns a new UUID.
  - `crypto.ulid`: Returns a new ULID.
- Added [`io.sqlite`](/manual/sqlite), which opens a database of the SQLite engine that the runtime embeds.
- Added `network.serve` and `network.lines`.
  - [`network.serve`](/manual/network#http-server): Serves HTTP/1.1 or HTTPS with one detached coroutine per connection and hands an upgraded connection, such as a WebSocket, to the handler.
  - [`network.lines`](/manual/api#network.lines): Returns an iterator over the lines of text that a coroutine yields in parts.
- Added [TLS sockets](/manual/network#tls-sockets) with `network.tls.connect`, `tcp_socket:starttls`, and `tcp_socket:tlsinfo`.
  - `network.tls.connect`: Opens a TCP connection, runs a TLS handshake over it, and returns the TLS socket.
  - `tcp_socket:starttls`: Starts TLS over a connected TCP socket, as the client or as the server.
  - `tcp_socket:tlsinfo`: Returns what the TLS handshake of a socket settled.
- Added `tcp_socket:reader`, `tcp_socket.input`, `tcp_socket.output`, `tcp_server.accepted`, `tcp_server:getsockname`, and `udp_socket:getsockname`.
  - [`tcp_socket:reader`](/manual/api#tcp_socket:reader): Returns a coroutine that yields the data of the socket as it arrives.
  - [`tcp_socket.input`](/manual/api#tcp_socket.input): Holds the input of the socket as a coroutine.
  - [`tcp_socket.output`](/manual/api#tcp_socket.output): Holds the output of the socket as a coroutine that sends what it is resumed with.
  - [`tcp_server.accepted`](/manual/api#tcp_server.accepted): Holds the accepted connections of the server as a coroutine.
  - [`tcp_server:getsockname`](/manual/api#tcp_server:getsockname): Returns the address and the port that the server is bound to.
  - [`udp_socket:getsockname`](/manual/api#udp_socket:getsockname): Returns the local address and port of the socket.
- Added the [`stream`](/manual/network#streamed-bodies) option of `network.fetch`, which returns the response body as a coroutine that hands it over in parts.
- Added [list values](/manual/network#responses) for the headers of a `network.serve` response and of a `network.fetch` request, which send one header line per element.
- Added `os.spawn`, `os.signal`, `os.setenv`, and `os.pid`.
  - [`os.spawn`](/manual/processes#running-a-program): Starts a program without a shell and returns a process object with its pipes and its exit.
  - [`os.signal`](/manual/processes#signals): Returns a coroutine that hands over the named signals as they arrive.
  - [`os.setenv`](/manual/api#os.setenv): Sets or removes an environment variable.
  - [`os.pid`](/manual/api#os.pid): Returns the id of the running process.
- Added `fs.stat`, `fs.walk`, `fs.watch`, `fs.sync`, and `file:sync`.
  - [`fs.stat`](/manual/filesystem#inspecting-a-path): Returns a table that describes a file, a directory, or a link.
  - [`fs.walk`](/manual/filesystem#walking-a-directory-tree): Returns an iterator that visits every entry of a directory tree.
  - [`fs.watch`](/manual/filesystem#watching-for-changes): Returns a coroutine that hands over each change to a file or a directory.
  - [`fs.sync`](/manual/filesystem#durable-writes): Writes the entries of a directory to the storage device.
  - [`file:sync`](/manual/filesystem#durable-writes): Writes the data of a file to the storage device.
- Added [recursive globs](/manual/filesystem#listing-a-directory) to `fs.list`, in which a glob with `/` or `**` matches entries in subdirectories.
- Added `file:isatty` and `file:setraw`.
  - [`file:isatty`](/manual/api#file:isatty): Returns `true` when the file handle is a terminal.
  - [`file:setraw`](/manual/api#file:setraw): Switches the terminal of a file handle to raw input and back.
- Added `vector.fromstring`, `vector.tostring`, `vector.get`, `vector.set`, `vector.find`, and `vector.copy`.
  - [`vector.fromstring`](/manual/text#strings-to-bytes-and-back): Returns a vector that holds the bytes of a string.
  - [`vector.tostring`](/manual/text#strings-to-bytes-and-back): Decodes a range of bytes as text, strictly or with replacement characters.
  - [`vector.get`](/manual/text#single-bytes): Returns the byte at an offset.
  - [`vector.set`](/manual/text#single-bytes): Stores a byte at an offset.
  - [`vector.find`](/manual/api#vector.find): Returns the offset of the first occurrence of a byte sequence.
  - [`vector.copy`](/manual/api#vector.copy): Copies bytes from one vector into another.
- Added the [`vector.archive.zip` and `vector.archive.tar`](/manual/text#archives) libraries, which read and write ZIP and tar archives.
  - `list`: Returns the entries of an archive.
  - `read`: Returns the contents of one file of an archive as a vector.
  - `pack`: Writes an archive and returns it as a vector.
  - `unpack`: Writes every entry of an archive under a directory.
- Added the [`"base64url"` and `"base32"`](/manual/text#binary-to-text-encodings) encodings to `string.transcode`.
- Added `debug.check`, `debug.jit`, `debug.getcontext`, and `debug.setcontext`.
  - [`debug.check`](/manual/api#debug.check): Returns the diagnostics of `lus check` for a source string.
  - [`debug.jit`](/manual/api#debug.jit): Reports the settings of the JIT and whether a function has machine code.
  - [`debug.getcontext`](/manual/api#debug.getcontext): Returns a `<context>` variable as a coroutine sees it.
  - [`debug.setcontext`](/manual/api#debug.setcontext): Assigns a `<context>` variable for a coroutine.
- Changed strings to hold [text indexed by character](/manual/text#strings), so `#s`, `string.sub`, slices, and the pattern functions count characters, `string.byte` returns code points, and `string.char` takes code points.
- Changed the standard library to [return raw bytes as vectors](/manual/text#bytes-in-the-standard-library), which applies to `string.pack`, `string.dump`, the `vector.archive` compressors, binary file reads, socket receives, and the body that `network.fetch` returns.
- Changed `load` to accept a vector from `string.dump` as a [compiled chunk](/manual/text#compiled-chunks).
- Changed files opened in [text mode](/manual/text#files) to raise an error for a read of bytes that are not valid UTF-8, unless the `{ lossy = true }` option of `io.open` replaces them with U+FFFD.
- Changed the interpolation of a vector to raise an error that names [`vector.tostring`](/manual/text#strings-to-bytes-and-back).
- Changed the operations of TCP and UDP sockets, `network.fetch`, and `worker.receive` into [suspension points](/manual/concurrency#suspension-points), which let the detached coroutines run while their caller waits.
- Changed the default of `package.path` to `./?.lus;./?/init.lus;./?.lua;./?/init.lua`, which the [`LUS_PATH`](/manual/guide#search-paths) environment variable replaces.
- Deprecated the following functions, which `lus check` reports under the code [`deprecated`](/manual/tools#lua-idioms-with-a-lus-form).
  - `utf8.char`: `string.char` replaces it.
  - `utf8.codepoint`: `string.byte` replaces it.
  - `utf8.codes`: A numeric `for` from 1 to `#s` with `string.byte` replaces it.
  - `utf8.len`: `#s` replaces it.
  - `utf8.offset`: `i + n - 1` replaces it, because positions count characters.
  - `utf8.charpattern`: The pattern `"."` replaces it.
  - `string.len`: `#s` replaces it.
  - `vector.size`: `#v` replaces it.
  - `string.join`: `table.concat` replaces it.
  - `os.time`: `time.now():epoch()` replaces it, or `time.zoned` for a table of fields.
  - `os.date`: The `format` and `at` methods of `time.instant(t)` replace it.
  - `os.difftime`: `t2 - t1` replaces it.
  - `dofile`: `assert(loadfile(path))()` replaces it.
- Removed the loading of [C modules](/manual/lua#c-modules) with `package.cpath` and `package.loadlib`, so native code extends Lus as part of a host program.

### Runtime

- Added a [baseline JIT](/manual/guide#the-baseline-jit), which compiles the functions that run often to machine code on aarch64 and x86-64 processors.
- Added an [optimizing tier](/manual/guide#the-optimizing-tier), which compiles again the code that stays hot, with predicted types, numbers in processor registers, and small functions compiled into their callers.
- Added a [JIT for the WebAssembly build](/manual/webassembly#the-jit), which compiles hot functions to WebAssembly modules that the JavaScript host instantiates.
- Added the [`LUS_JIT`, `LUS_JIT_THRESHOLD`, and `LUS_GC_THREADS`](/manual/cli#environment-variables) environment variables.
  - `LUS_JIT`: Selects the interpreter alone, the baseline JIT, or both compilers.
  - `LUS_JIT_THRESHOLD`: Sets how many calls and loop iterations a function makes before the JIT compiles it.
  - `LUS_GC_THREADS`: Sets the number of threads that the garbage collector marks with.
- Added [`lus.h`](/manual/embedding), a stack based C embedding interface in which every function that can fail returns a status.
- Added the [host permission policy](/manual/embedding#permissions) to the embedding interface.
  - `lus_grant`, `lus_reject`, and `lus_seal`: Set the starting permissions of a state.
  - `lus_onrequest`: Registers a function that decides the pledges of a script.
  - `lus_defcapability`: Declares a capability of the host.
  - `lus_require` and `lus_allowed`: Check a permission from a C function.
- Added `lus_runpending` and `lus_pending` to the embedding interface.
  - `lus_runpending`: Runs the detached coroutines of a state for one pass or to their end.
  - `lus_pending`: Counts the detached coroutines of a state.
- Added the [`lus-wasm`](/manual/webassembly) package, which runs the WebAssembly build in browsers, web workers, and Node.
- Added [release archives](/manual/releases#downloads) for Linux on aarch64, 32-bit ARM, riscv64, loong64, ppc64le, and s390x, for FreeBSD on x86_64 and aarch64, for macOS on x86_64, and for Windows on aarch64.
- Added the [`-Dnet`, `-Dworkers`, `-Dsqlite`, `-Darchive`, and `-Djit`](/manual/compiling#optional-libraries) build options, each of which omits one part of the runtime from a build.
- Changed the [build](/manual/compiling#building) to need the Zig compiler alone, which compiles SQLite, Zstandard, and Brotli from source.
- Changed the [interpreter](/manual/guide#the-interpreter) to specialize instructions in place and to cache the slot of each table access with a string key.
- Changed the [garbage collector](/manual/guide#the-garbage-collector) to a precise, non-moving, generational collector that marks large heaps on several threads.
- Changed each [release archive](/manual/releases#archive-layout) to hold the interpreter, the static and shared embedding libraries, and the `lus.h` header.
- Changed the Linux release builds to link musl statically, so one binary runs on every Linux distribution of its architecture.
- Removed the `lua.h`, `lauxlib.h`, and `lualib.h` embedding headers, which [`lus.h`](/manual/embedding) replaces.

### Tools

- Added [`lus test`](/manual/testing), a test runner that runs the `_test` functions of `*_test.lus` files in parallel, with one process and one temporary directory per file.
  - `assert`: Reports the values of the operands of a failed comparison in a test file.
  - `raises`, `same`, `skip`, and `snapshot`: Test for an error, compare two structures, skip a test, and compare a value with a recorded copy.
  - `NAME_cases`: Runs the test `NAME_test` once per entry of the table.
  - [`--coverage`](/manual/testing#coverage): Reports which lines of the code under test ran and writes an lcov tracefile with `--coverage-out`.
  - [`--bench`](/manual/testing#benchmarks): Measures the functions whose names end in `_bench` and compares them with a saved baseline.
  - [`--doc`](/manual/testing#doc-tests): Runs the code blocks of Markdown files and of doc comments.
  - `--list`: Prints each test and benchmark that a run would start.
- Added [`lus fmt`](/manual/tools#formatting), which formats source files and writes the [strict style](/manual/tools#the-strict-style) with `--strict`.
- Added [`lus check`](/manual/tools#checking), which reports compile errors, warnings, and hints with stable codes, as text or as JSON.
  - [`--fix`](/manual/tools#fixes): Applies the rewrites that keep the behavior of the program.
  - `--explain`: Prints why a diagnostic code matters and how to resolve it.
  - `--strict`: Reports where a file departs from the strict style.
  - `--list`: Prints every diagnostic code with its severity and summary.
  - [`-- lus: allow(CODE)`](/manual/tools#suppressing-a-diagnostic): Suppresses the named warnings and hints for a line, a statement, or a file.
- Added [`lus doc`](/manual/tools#documentation), which generates Markdown, JSON, or HTML reference documentation from doc comments.
- Added [`lus ast`](/manual/tools#lus-ast), which prints the syntax tree of a file as JSON.
- Added [`lus build`](/manual/tools#standalone-executables), which bundles a script and the modules it requires into one executable.
  - [`--aot`](/manual/tools#compiling-ahead-of-time): Compiles the program to machine code from a training run.
  - [`--link-object`](/manual/tools#linking-the-runtime): Links the executable from the runtime as a link object and keeps only the parts that the program reaches.
- Added [`lus compile`](/manual/tools#binary-chunks), which writes a script as a binary chunk.
- Added [`lus debug`](/manual/tools#debugger), a Debug Adapter Protocol server with breakpoints, stepping, pausing, and inspection of variables.
- Added [`lus help`](/manual/tools#standard-library-reference), which prints the reference of the standard library in the terminal.
- Added [`lus agents init`](/manual/tools#agent-setup), which writes the Lus agent skills and a section of `AGENTS.md` into a project.
- Added [`lus tree`](/manual/cli#lus-tree), which prints the modules that a script requires as a tree.
- Added [`lus lsp`](/manual/cli#lus-lsp), which runs the language server that is part of `lus` on standard input and output.
- Added [`lus version`](/manual/cli#lus-version), which installs releases of Lus side by side and selects the default.
- Added [`lus +VERSION`](/manual/cli#lus-version), which runs one command under another installed release.
- Added the following [options](/manual/cli#options) to `lus`.
  - `-F name[=value]`: Defines a build flag.
  - `--offline`: Loads remote modules from the module cache only.
  - `--reload`: Asks the server of every remote module whether it changed before the program runs.
  - `--no-prefetch`: Downloads each remote module at its `require`.
  - `--dis`: Prints the bytecode of a script.
- Added [refactorings](/manual/ide-setup#refactoring) to the language server, which extract a local or a function, inline a local, and convert between concatenation and interpolation.
- Added a [call hierarchy](/manual/ide-setup#call-hierarchy) to the language server, which shows the callers and the callees of a function.
- Added quick fixes to the language server for the diagnostics that [`lus check --fix`](/manual/tools#fixes) rewrites.
- Added a [Testing view](/manual/ide-setup#testing) to the VS Code extension, which lists the tests and benchmarks of the workspace and marks the covered lines.
- Added the [`lus` debugger](/manual/ide-setup#debugging) to the VS Code extension, which starts `lus debug`.
- Added [package completion](/manual/ide-setup#package-completion) to the VS Code extension, inside the string of a `require`.
- Added the VS Code extension to the [Visual Studio Marketplace](/manual/ide-setup#vscode-based-editors) under the identifier `lus-language.lus`.
- Added a [Claude Code plugin](/manual/ide-setup#claude-code), which installs the Lus skills and registers `lus lsp` for `.lus` files.
- Changed [`--include`](/manual/guide#preincluded-modules) to compile modules when the interpreter starts, so `require` loads them with no `load` or `fs:read` permission.
- Removed the following commands and options of `lus`.
  - `lus format`: `lus fmt` replaces it.
  - `lusc`: `lus compile` and `lus --dis` replace it.
  - `--standalone`: `lus build` replaces it.
  - `--ast-json` and `--ast-graph`: `lus ast` replaces them.
  - `-Wpedantic`: `lus check` replaces it.
  - `--strip-debug`: `lus compile --strip` replaces it for a compiled script.
  - `--no-fastcall`: The fast call path of every builtin is always on.
- Removed the `LUA_INIT` and `LUA_PATH` environment variables, which the `-e` and `-l` options and [`LUS_PATH`](/manual/cli#environment-variables) replace.

### Security

- Added the [`--sandbox`](/manual/cli#options) option, which seals the permissions after the `-P` grants and before any code runs.
- Added the [`env:read`, `env:write`, and `network:server`](/manual/permissions#permission-names) permissions.
  - `env:read`: Allows reading environment variables with `os.getenv`.
  - `env:write`: Allows setting and removing environment variables with `os.setenv`.
  - `network:server`: Allows serving HTTP with `network.serve`.
- Added [program values](/manual/permissions#program-values) to the `exec` permission, which select the programs that `os.spawn` may start.
- Added signature checks to [remote modules](/manual/guide#modules-from-the-network), so `lus` refuses a package of `atmosp.here` whose signature or content does not match.
- Added signature and digest checks to [`lus version install`](/manual/releases#downloads), which verifies the Ed25519 signature of the release index and the SHA-256 digest of each archive.
- Added [build provenance attestations](/manual/releases#checking-download-integrity) to every file of a release, which `gh attestation verify` checks.
- Added [code signatures](/manual/releases#code-signatures) to the release binaries, a notarized Developer ID signature on macOS and an Authenticode signature on Windows.
- Changed TCP [line and all-data receives](/manual/network#receiving-from-a-tcp-socket) to stop at a limit, by default 1 MiB for a line and 64 MiB for all data, which the `max_bytes` argument sets.

### Website

- Added manual pages for the libraries and the tools.
  - Libraries: [Text and bytes](/manual/text), [Data formats](/manual/data), [Filesystem](/manual/filesystem), [Network](/manual/network), [Processes and signals](/manual/processes), [Time](/manual/time), [SQLite](/manual/sqlite), [Cryptography](/manual/crypto), [Coroutines and workers](/manual/concurrency), and [Permissions](/manual/permissions).
  - Tools: [Testing](/manual/testing), [Developer tools](/manual/tools), [Embedding](/manual/embedding), and [WebAssembly](/manual/webassembly).
  - Guidance: [Lus for Lua programmers](/manual/lua), [Best practices](/manual/practices), and [Lus and other runtimes](/manual/runtimes), which compares the runtimes on measured benchmarks.
- Added the [agents page](/agents), `llms.txt`, and a Markdown copy of every manual page for coding agents.
- Changed the [guide](/manual/guide) into the complete reference of the language, which holds the content of the former acquis pages.
- Changed the [examples page](/examples) to group its programs into sections.
- Changed the [playground](/playground) to run programs on the `lus-wasm` host in a Web Worker, with a limit of five seconds per run and of 256 KiB of output.

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
- Fixed a worker thread leaving its mutex locked after an error (including a worker script that fails to load or raises at runtime), which could deadlock a parent waiting on it.
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
- Release binaries for Linux and macOS are now built with profile-guided optimization (`tools/pgo-build.sh`), 15 to 45% faster across VM micro-benchmarks than a plain release build.
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
> This changelog denotes differences between Lus and Lua 5.5 RC 2. Lua 5.5 most (in)famously introduces the `global` assignment statement, which is not a Lus-specific feature.

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
