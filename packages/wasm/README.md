# lus-wasm

This package holds the Lus 2.0 runtime compiled to WebAssembly and the small JavaScript host that runs it. The website playground and the VS Code extension both load the runtime through it.

## Building

The module is built from the Zig runtime in `runtime/`. The following command builds it and copies it to `dist/lus.wasm`:

```sh
mise run wasm
```

The task runs `zig build wasm` in `runtime/`, which writes `runtime/zig-out/wasm/lus.wasm`. The build keeps the safety checks of a ReleaseSafe build, because the playground runs untrusted code and a failed check must trap rather than corrupt memory. Pass `-Dwasm-optimize=small` to `zig build wasm` for a build about 15 percent smaller without them.

The module targets `wasm32-wasi` and is a WASI reactor. It has no `main`. It exports every function declared in `runtime/include/lus.h`, the `lus_wasm_*` helpers of `runtime/src/wasm.zig`, and its memory.

The library options of the native build also apply here. On WebAssembly the network library (`-Dnet`) and the worker library (`-Dworkers`) are left out by default, since WASI has neither sockets nor threads. SQLite (`-Dsqlite`) and the `vector.archive` codecs (`-Darchive`) are included. The host has no processes, so `io.popen` and `os.execute` raise "not available on this platform", and `os.execute()` without a command returns false.

## Testing

The tests run the module under Node:

```sh
mise run wasm:test
```

They cover hello world, errors with their traceback, pledge denials, the in-memory file system, string, vector, and JSON functions, SQLite, the archive codecs, `os.exit`, the playground interface, a language server session, and the JIT.

Two scripts measure the JIT. `mise run wasm:conformance` runs `scripts/conformance.mjs`, which runs the conformance suite and the language server tests through the module with the JIT off, on, and eager, and fails when the modes disagree on any test. `mise run wasm:bench` runs `bench/run.mjs`, which times the benchmarks of `tests/bench` with the JIT off and on.

## The JIT

Hot functions compile to WebAssembly (`spec/design/wasmjit.md`). The runtime emits a small module for each one, and the host in `src/jit.js` compiles and instantiates it and installs its function in the function table of the module, which `lus.wasm` exports for this purpose. `Lus.load` sets the host up for every instance, and `lus.jit` holds its statistics. Modules up to 4 MiB compile synchronously, and larger ones compile in the background while the function keeps running in the interpreter.

`LUS_JIT` and `LUS_JIT_THRESHOLD` in `lus.env` set the policy of each state, as they do for the native runtime: `off`, `on` (the default), or `eager`. The option `jit: false` of `Lus.load` leaves the host without a compiler, and the module then interprets everything. `lus.wasm` imports nothing but WASI, so a plain WASI runner such as wasmtime runs it too, interpreted.

## Using the host

`Lus.load` compiles the module and returns a host. One host holds any number of states, and they share one in-memory file system (`lus.fs`) and one set of environment variables (`lus.env`). In Node, `loadLus` reads `dist/lus.wasm` from disk:

```js
import { loadLus } from "lus-wasm";

const lus = await loadLus();
const result = lus.run('print("hello")');
// { ok: true, stdout: "hello\n", stderr: "", output: "hello\n",
//   error: null, traceback: null, exitCode: 0, truncated: false }
```

In a browser or a worker, import `lus-wasm/browser` and pass the module bytes, a `Response`, or a URL:

```js
import { Lus } from "lus-wasm/browser";

const lus = await Lus.load(new URL("/wasm/lus.wasm", location.href));
```

`run(source, options)` runs a whole program in a fresh state and closes it afterwards. The options are `args` (passed as `...` and `arg`), `pledges` (host grants, like `lus -P`), `stdin`, `files` (written to the file system first), `chunkname`, and `maxOutputBytes`. The result separates standard output and standard error and also gives them interleaved in write order as `output`. When the program fails, `error` holds the message and `traceback` the stack traceback. A call to `os.exit` sets `exitCode`.

The host also keeps the interface of the legacy emscripten glue, so the current consumers change little:

- `create(options)` returns a long-lived state with the standard libraries open, and `destroy(state)` closes it.
- `execute(state, code)` runs playground input. An expression prints its values, statements run as a chunk, and the result is the output followed by the error message, limited to 256 KiB.
- `loadLsp(state, source)` loads the language server entry point. It returns an empty string on success or an error message. `getLspSource()` reads the entry point from `/lus-language/wasm.lus`.
- `handleMessage(state, json)` dispatches one JSON-RPC body and `handleFrame(state, frame)` one complete frame. Both return the framed responses as a string.

Each call returns a JavaScript string, so the hosts no longer copy strings in and out of linear memory themselves. Any C function of `lus.h` is also available through `lus.exports` for hosts that need more.

When a program calls `os.exit` or a safety check traps, the WebAssembly instance cannot continue. The host then starts a fresh instance over the same file system on the next call, and every state of the old instance becomes invalid. `run` reports a trap as an error with exit code 134. The other calls throw, as the legacy glue did.

The WASI layer is written by hand in `src/wasi.js` and needs no dependency. It captures standard output and standard error, serves standard input from `run`, keeps files in memory with `/` as the only preopened directory, and provides the environment, the clocks, randomness, and sleeping. A sleep blocks with `Atomics.wait` where the platform allows it, which includes Node and web workers.

## How the site uses it

The site build (`packages/site/scripts/fetch-wasm.mjs`) places each runtime at `public/wasm/<version>/lus.wasm` and lists the stable and unstable channels in `public/wasm/manifest.json`. Releases contribute their `lus.wasm`, checked against their `SHA256SUMS`. A local `dist/lus.wasm` becomes the unstable channel under the version in `runtime/build.zig.zon`, so a checkout can try its own runtime in the playground after `mise run wasm`.

The playground worker (`packages/site/src/workers/playground-worker.ts`) loads the module with `Lus.load` from `lus-wasm/browser` and keeps one state from `create()` for the session. Each run calls `execute(state, code)`. After `os.exit` ends the instance, the worker opens a fresh state on the next run. A trap makes `execute` throw, and the worker reports it as a `runtime-error` and reloads.

## How the VS Code extension uses it

The extension packages `wasm/lus.wasm` and the language server sources in `language-server/`. Its build (`packages/vscode/esbuild.mjs`) copies both from this package and from `packages/language-server`, and bundles this package into the extension. `LusWasm.load` in `packages/vscode/src/wasm.ts` calls `loadLus` with the packaged module and `mountLanguageServer` with the packaged sources. A CommonJS bundle has no `import.meta.url`, so the extension passes both paths explicitly. `scripts/smoke-wasm.mjs` in the extension runs a language server session and playground input against the packaged files.
