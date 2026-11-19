// The JavaScript host for lus.wasm. It instantiates the module with the
// WASI host in wasi.js and drives Lus states through the C embedding
// interface that the module exports (runtime/include/lus.h).
//
// This file runs in browsers, workers, and Node. Node-only helpers live
// in node.js.

import { MemFS } from "./memfs.js";
import { Wasi, WasiExit } from "./wasi.js";

export { MemFS, WasiExit };

const LUS_OK = 0;
const LUS_MULTRET = -1;
const LUS_TSTRING = 4;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The largest JSON-RPC body or frame the language server accepts. */
export const MAX_LSP_FRAME_BYTES = 16 * 1024 * 1024;

/** Default output limit of `execute`, matching the legacy playground. */
export const EXEC_OUTPUT_BYTES = 256 * 1024;

const TRUNCATION_MESSAGE = "\n[Output truncated at 256 KiB.]\n";

/** Collects the bytes written to standard output and standard error. */
class Capture {
  constructor() {
    this.reset();
  }

  reset(limit = Infinity) {
    this.chunks = [];
    this.streams = [];
    this.bytes = 0;
    this.limit = limit;
    this.truncated = false;
    this.discardStderr = false;
  }

  write(stream, data) {
    if (stream === "stderr" && this.discardStderr) return;
    if (this.bytes >= this.limit) {
      this.truncated = true;
      return;
    }
    let chunk = data;
    if (this.bytes + chunk.length > this.limit) {
      chunk = chunk.subarray(0, this.limit - this.bytes);
      // Never split a UTF-8 sequence.
      let end = chunk.length;
      while (end > 0 && (data[end] & 0xc0) === 0x80) end--;
      chunk = chunk.subarray(0, end);
      this.truncated = true;
    }
    this.chunks.push(chunk);
    this.streams.push(stream);
    this.bytes += chunk.length;
  }

  text(stream) {
    const parts = this.chunks.filter((_, i) => !stream || this.streams[i] === stream);
    let size = 0;
    for (const p of parts) size += p.length;
    const all = new Uint8Array(size);
    let off = 0;
    for (const p of parts) {
      all.set(p, off);
      off += p.length;
    }
    return decoder.decode(all);
  }
}

/** Compiles lus.wasm from bytes, a Response, a URL, or a compiled module. */
async function compile(source) {
  if (source instanceof WebAssembly.Module) return source;
  if (typeof Response !== "undefined" && source instanceof Response) {
    if (typeof WebAssembly.compileStreaming === "function") {
      return WebAssembly.compileStreaming(source);
    }
    return WebAssembly.compile(await source.arrayBuffer());
  }
  if (source instanceof URL || typeof source === "string") {
    const response = await fetch(source);
    if (!response.ok) throw new Error(`Failed to fetch lus.wasm: ${response.status}`);
    return compile(response);
  }
  return WebAssembly.compile(source);
}

/**
 * A loaded lus.wasm. One instance holds any number of states, which share
 * the in-memory file system and the environment. If a run ends the
 * instance (through `os.exit` or a trap), the next call starts a fresh
 * instance over the same file system, and every state of the old
 * instance becomes invalid.
 */
export class Lus {
  /**
   * Compiles and instantiates lus.wasm.
   * @param {BufferSource | WebAssembly.Module | Response | URL | string} source
   * @param {{ fs?: MemFS, env?: Record<string, string> }} [options]
   */
  static async load(source, options = {}) {
    const module = await compile(source);
    const lus = new Lus(module, options, false);
    await lus.instantiateAsync();
    return lus;
  }

  /** Use `Lus.load`. The constructor exists for hosts that compile the module themselves. */
  constructor(module, options = {}, instantiate = true) {
    this.module = module;
    this.fs = options.fs ?? new MemFS();
    this.env = options.env ?? {};
    this.capture = new Capture();
    this.stdinQueue = [];
    this.generation = 0;
    this.lspStates = new Set();
    if (instantiate) this.instantiate();
  }

  makeWasi() {
    return new Wasi({
      fs: this.fs,
      env: () => this.env,
      stdout: (data) => this.capture.write("stdout", data),
      stderr: (data) => this.capture.write("stderr", data),
      stdin: () => this.stdinQueue.shift() ?? null,
    });
  }

  adopt(instance, wasi) {
    wasi.bind(instance.exports.memory);
    instance.exports._initialize?.();
    this.wasi = wasi;
    this.exports = instance.exports;
    this.generation++;
    this.lspStates.clear();
    this.dead = false;
  }

  async instantiateAsync() {
    const wasi = this.makeWasi();
    const instance = await WebAssembly.instantiate(this.module, wasi.imports);
    this.adopt(instance, wasi);
  }

  instantiate() {
    const wasi = this.makeWasi();
    this.adopt(new WebAssembly.Instance(this.module, wasi.imports), wasi);
  }

  ensureLive() {
    if (this.dead) this.instantiate();
  }

  /**
   * Runs a call into the module. A WASI exit or a trap leaves the instance
   * in an unknown state, so it is replaced before the next call.
   */
  guard(fn) {
    try {
      return fn();
    } catch (error) {
      this.dead = true;
      throw error;
    }
  }

  // --- Memory helpers ---------------------------------------------------

  get memory() {
    return new Uint8Array(this.exports.memory.buffer);
  }

  /** Copies `bytes` into fresh linear memory. The caller frees it. */
  alloc(bytes, terminate = true) {
    const ptr = this.exports.lus_wasm_alloc(bytes.length + (terminate ? 1 : 0));
    if (!ptr) throw new Error("lus.wasm is out of memory");
    const mem = this.memory;
    mem.set(bytes, ptr);
    if (terminate) mem[ptr + bytes.length] = 0;
    return ptr;
  }

  withCString(text, fn) {
    const ptr = this.alloc(encoder.encode(text));
    try {
      return fn(ptr);
    } finally {
      this.exports.lus_wasm_free(ptr);
    }
  }

  withBytes(bytes, fn) {
    const ptr = this.alloc(bytes, false);
    try {
      return fn(ptr, bytes.length);
    } finally {
      this.exports.lus_wasm_free(ptr);
    }
  }

  cString(ptr) {
    if (!ptr) return null;
    const mem = this.memory;
    let end = ptr;
    while (mem[end] !== 0) end++;
    return decoder.decode(mem.subarray(ptr, end));
  }

  /** Reads the string at stack index `idx`, converting other values. */
  stackString(l, idx) {
    const x = this.exports;
    let pushed = false;
    if (x.lus_type(l, idx) !== LUS_TSTRING) {
      if (x.lus_stringify(l, idx) !== LUS_OK) {
        x.lus_settop(l, -2);
        return "(error object is not a string)";
      }
      idx = -1;
      pushed = true;
    }
    const lenPtr = x.lus_wasm_alloc(4);
    try {
      const ptr = x.lus_tostring(l, idx, lenPtr);
      const len = new DataView(x.memory.buffer).getUint32(lenPtr, true);
      return decoder.decode(this.memory.subarray(ptr, ptr + len));
    } finally {
      x.lus_wasm_free(lenPtr);
      if (pushed) x.lus_settop(l, -2);
    }
  }

  // --- States -------------------------------------------------------------

  /**
   * Creates a state with the standard libraries open and returns its
   * handle. `pledges` are granted by the host, like `lus -P`.
   */
  create(options = {}) {
    this.ensureLive();
    return this.guard(() => {
      const x = this.exports;
      const l = x.lus_newstate();
      if (!l) throw new Error("Failed to create a Lus state");
      if (x.lus_wasm_environ(l) !== 0 || x.lus_openlibs(l) !== LUS_OK) {
        x.lus_wasm_close(l);
        throw new Error("Failed to open the Lus libraries");
      }
      for (const spec of options.pledges ?? []) {
        const status = this.withCString(spec, (p) => x.lus_grant(l, p));
        if (status !== LUS_OK) {
          const message = this.stackString(l, -1);
          x.lus_wasm_close(l);
          throw new Error(`Invalid pledge ${JSON.stringify(spec)}: ${message}`);
        }
      }
      x.lus_settop(l, 0);
      return l;
    });
  }

  /** Closes a state. */
  destroy(l) {
    if (this.dead || !l) return;
    this.lspStates.delete(l);
    this.guard(() => {
      this.exports.lus_wasm_flush(l);
      this.exports.lus_wasm_close(l);
    });
  }

  /** Loads `code` and leaves the function on the stack. Returns the status. */
  loadChunk(l, code, chunkname) {
    const bytes = encoder.encode(code);
    return this.withBytes(bytes, (ptr, len) =>
      this.withCString(chunkname, (name) => this.exports.lus_load(l, ptr, len, name)),
    );
  }

  /** Pops the error at the top of the stack and returns its message and traceback. */
  takeError(l) {
    const message = this.stackString(l, -1);
    const traceback = this.cString(this.exports.lus_traceback(l));
    this.exports.lus_settop(l, 0);
    return { message, traceback };
  }

  /**
   * Runs a complete program in a fresh state and returns everything it
   * produced.
   *
   * @param {string} source
   * @param {object} [options]
   * @param {string} [options.chunkname] Defaults to "=(playground)".
   * @param {string[]} [options.args] The script arguments, as `...` and `arg`.
   * @param {string[]} [options.pledges] Host grants, like `lus -P`.
   * @param {string | Uint8Array} [options.stdin] Bytes for `io.read`.
   * @param {Record<string, string>} [options.files] Files to write first.
   * @returns {{ ok: boolean, stdout: string, stderr: string, output: string,
   *   error: string | null, traceback: string | null, exitCode: number }}
   */
  run(source, options = {}) {
    if (options.files) this.fs.mount(options.files);
    this.capture.reset(options.maxOutputBytes ?? Infinity);
    this.stdinQueue = options.stdin === undefined ? [] : [typeof options.stdin === "string" ? encoder.encode(options.stdin) : options.stdin];
    let error = null;
    let traceback = null;
    let exitCode = 0;
    try {
      const l = this.create({ pledges: options.pledges });
      try {
        this.guard(() => {
          const x = this.exports;
          const args = options.args ?? [];
          this.setArgTable(l, args);
          let status = this.loadChunk(l, source, options.chunkname ?? "=(playground)");
          if (status === LUS_OK) {
            for (const a of args) this.pushString(l, a);
            status = x.lus_pcall(l, args.length, 0);
          }
          if (status !== LUS_OK) {
            ({ message: error, traceback } = this.takeError(l));
            exitCode = 1;
          }
          x.lus_wasm_flush(l);
        });
      } finally {
        this.destroy(l);
      }
    } catch (e) {
      if (e instanceof WasiExit) {
        exitCode = e.code;
      } else if (e instanceof WebAssembly.RuntimeError) {
        // A failed safety check prints its reason to standard error and
        // traps. The next call starts a fresh instance.
        error = `the Lus runtime crashed (${e.message})`;
        exitCode = 134;
      } else {
        throw e;
      }
    }
    return {
      ok: exitCode === 0,
      stdout: this.capture.text("stdout"),
      stderr: this.capture.text("stderr"),
      output: this.capture.text(),
      error,
      traceback,
      exitCode,
      truncated: this.capture.truncated,
    };
  }

  pushString(l, s) {
    const bytes = encoder.encode(s);
    this.withBytes(bytes, (ptr, len) => this.exports.lus_pushlstring(l, ptr, len));
  }

  setArgTable(l, args) {
    const x = this.exports;
    x.lus_newtable(l, args.length, 1);
    this.pushString(l, "(playground)");
    x.lus_rawseti(l, -2, 0n);
    args.forEach((a, i) => {
      this.pushString(l, a);
      x.lus_rawseti(l, -2, BigInt(i + 1));
    });
    this.withCString("arg", (p) => x.lus_setglobal(l, p));
  }

  // --- The legacy playground and language server interface ------------------

  /**
   * Runs `code` in the long-lived state `l` like the legacy playground.
   * An expression prints its values. Statements run as a chunk. The
   * result is standard output and standard error in order, followed by
   * the error message when the code fails, limited to 256 KiB.
   */
  execute(l, code) {
    if (this.dead) return "Error: the Lus runtime stopped. Create a new state.";
    this.capture.reset(EXEC_OUTPUT_BYTES - TRUNCATION_MESSAGE.length);
    let tail = "";
    try {
      this.guard(() => {
        const x = this.exports;
        x.lus_settop(l, 0);
        let status = this.loadChunk(l, `return ${code}`, "=(playground expression)");
        if (status === LUS_OK) {
          status = x.lus_pcall(l, 0, LUS_MULTRET);
          if (status === LUS_OK) {
            const n = x.lus_gettop(l);
            if (n > 0) {
              this.withCString("print", (p) => x.lus_getglobal(l, p));
              x.lus_insert(l, 1);
              status = x.lus_pcall(l, n, 0);
            }
          }
        } else {
          x.lus_settop(l, 0);
          status = this.loadChunk(l, code, "=(playground)");
          if (status === LUS_OK) status = x.lus_pcall(l, 0, 0);
        }
        x.lus_wasm_flush(l);
        if (status !== LUS_OK) tail = this.takeError(l).message;
        x.lus_settop(l, 0);
      });
    } catch (e) {
      if (!(e instanceof WasiExit)) throw e;
      tail = `[Program exited with status ${e.code}.]\n`;
    }
    let out = this.capture.text() + tail;
    if (this.capture.truncated) out += TRUNCATION_MESSAGE;
    return out;
  }

  /**
   * Loads the language server entry `source` (packages/language-server/
   * wasm.lus) into `l`. The language server modules must be in the file
   * system under /lus-language. Returns "" on success or an error message.
   */
  loadLsp(l, source = this.getLspSource()) {
    this.capture.reset();
    this.capture.discardStderr = true;
    return this.guard(() => {
      const x = this.exports;
      x.lus_settop(l, 0);
      const setup = this.loadChunk(l, "package.path = '/?.lus;/?/init.lus;' .. package.path", "=(host)");
      if (setup !== LUS_OK || x.lus_pcall(l, 0, 0) !== LUS_OK) return this.takeError(l).message;
      let status = this.loadChunk(l, source, "@/lus-language/wasm.lus");
      if (status === LUS_OK) status = x.lus_pcall(l, 0, 0);
      x.lus_wasm_flush(l);
      if (status !== LUS_OK) return this.takeError(l).message;
      for (const name of ["_lsp_handle", "_lsp_handle_frame"]) {
        this.withCString(name, (p) => x.lus_getglobal(l, p));
        const ok = x.lus_isfunction(l, -1);
        x.lus_settop(l, 0);
        if (!ok) return `${name} not defined`;
      }
      this.lspStates.add(l);
      return "";
    });
  }

  callLsp(l, handler, input) {
    if (this.dead || !this.lspStates.has(l)) return "";
    this.capture.reset(MAX_LSP_FRAME_BYTES + 8 * 1024);
    this.capture.discardStderr = true;
    return this.guard(() => {
      const x = this.exports;
      x.lus_settop(l, 0);
      this.withCString(handler, (p) => x.lus_getglobal(l, p));
      this.pushString(l, input);
      const status = x.lus_pcall(l, 1, 0);
      x.lus_wasm_flush(l);
      x.lus_settop(l, 0);
      if (status !== LUS_OK) return lspError(-32603, "LSP dispatch failed");
      if (this.capture.truncated) return lspError(-32603, "Invalid LSP output frame");
      return this.capture.text("stdout");
    });
  }

  /** Dispatches one JSON-RPC body and returns the framed responses. */
  handleMessage(l, json) {
    if (encoder.encode(json).length > MAX_LSP_FRAME_BYTES) {
      return lspError(-32700, "JSON-RPC body exceeds 16 MiB");
    }
    return this.callLsp(l, "_lsp_handle", json);
  }

  /** Dispatches one complete Content-Length frame. */
  handleFrame(l, frame) {
    return this.callLsp(l, "_lsp_handle_frame", frame);
  }

  /** The language server entry, read from /lus-language/wasm.lus. */
  getLspSource() {
    try {
      return this.fs.readFile("/lus-language/wasm.lus", { encoding: "utf8" });
    } catch {
      throw new Error("The Lus language server is not in the file system");
    }
  }
}

function lspError(code, message) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: null, error: { code, message } });
  return `Content-Length: ${encoder.encode(body).length}\r\n\r\n${body}`;
}
