# lus-wasm

This package holds the Lus 2.0 runtime compiled to WebAssembly and the small JavaScript host that runs it. The website playground and the VS Code extension will both load the runtime through it.

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

They cover hello world, errors with their traceback, pledge denials, the in-memory file system, string, vector, and JSON functions, SQLite, the archive codecs, `os.exit`, the playground interface, and a language server session.

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

## How the site will consume it

The playground worker (`packages/site/src/workers/playground-worker.ts`) and its loader (`packages/site/src/lib/wasm-loader.ts`) will change as follows:

1. The site build copies `dist/lus.wasm` into `public/wasm/<version>/lus.wasm`. The release fetcher keeps downloading `lus.wasm` and `SHA256SUMS` but stops downloading `lus.web.js`, since the JavaScript host is bundled with the site from this package instead of being fetched and rewritten into a blob URL.
2. `loadLusWasm(release)` becomes `Lus.load(release.wasmUrl)` from `lus-wasm/browser`, followed by `create()`. The returned object keeps its `execute(code)` and `destroy()` methods by calling `lus.execute(state, code)` and `lus.destroy(state)`. The UTF-8 marshalling in `callWasmUtf8` goes away.
3. The worker keeps posting `runtime-error` when `execute` throws, which now happens after a trap. It may instead call `lus.run` to show the error and its traceback separately.

## How the VS Code extension will consume it

The extension (`packages/vscode/src/wasm.ts`) will change as follows:

1. The packaged files become `wasm/lus.wasm` and the language server sources. The extension copies `packages/language-server` into the package, since the module no longer embeds it, and drops `wasm/lus.mjs`.
2. `LusWasm.load(context)` becomes `loadLus(path.join(context.extensionPath, "wasm", "lus.wasm"))` followed by `mountLanguageServer(lus, languageServerDirectory)`. Both come from `lus-wasm`, which esbuild bundles into the extension. A CommonJS bundle has no `import.meta.url`, so the extension passes both paths explicitly.
3. `create`, `execute`, `loadLsp`, `handleMessage`, `destroy`, and `getLspSource` keep their names and signatures, so `extension.ts` and `lspTransport.ts` stay as they are. `wasmUtf8.ts` and `wasmAsset.ts` go away, and the 16 MiB input limit moves into the host, which answers an oversized body or a failed dispatch with the same JSON-RPC errors as the legacy glue.
4. `scripts/smoke-wasm.mjs` runs against the new host, or is replaced by the language server test of this package.
