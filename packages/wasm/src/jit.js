// The host side of the WebAssembly JIT (spec/design/wasmjit.md).
//
// lus.wasm compiles a hot function to a small WebAssembly module in its
// own memory and hands the bytes to the compile function registered here.
// The host instantiates the module against the memory of the runtime and
// the entries of its function table that the module imports, installs the
// compiled function in that table, and returns its index. The runtime then
// calls the function through `call_indirect`.
//
// A module can only call functions it imports, and imports are resolved
// when an instance is created, so the compile function reaches lus.wasm
// through its table: a two-line bridge module imports the JavaScript
// function and exports it again, which makes it a WebAssembly function
// that the table accepts.

const PENDING = -1; // 0xFFFFFFFF as an unsigned 32-bit result.

// (module
//   (type (func (param i32 i32 i32) (result i32)))
//   (import "h" "c" (func (type 0)))
//   (export "c" (func 0)))
const BRIDGE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x08, 0x01, 0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
  0x02, 0x07, 0x01, 0x01, 0x68, 0x01, 0x63, 0x00, 0x00,
  0x07, 0x05, 0x01, 0x01, 0x63, 0x00, 0x00,
]);

/**
 * Modules up to this many bytes compile synchronously by default. A
 * function of a few thousand instructions makes a module of a few hundred
 * kilobytes, and the longest function the runtime compiles makes one of
 * about five megabytes.
 */
export const JIT_SYNC_LIMIT = 4 * 1024 * 1024;

const now = typeof performance !== "undefined" ? () => performance.now() : () => Date.now();

/** Compiles and installs the modules that one instance of lus.wasm emits. */
export class WasmJit {
  /**
   * Registers a JIT host with `instance`. Returns null when the module
   * has no JIT or does not export its function table.
   * @param {WebAssembly.Instance} instance
   * @param {{ syncLimit?: number, onError?: (error: unknown) => void }} [options]
   */
  static attach(instance, options = {}) {
    const x = instance.exports;
    if (!(x.__indirect_function_table instanceof WebAssembly.Table) || typeof x.lus_wasm_jit_host !== "function") {
      return null;
    }
    const jit = new WasmJit(x, options);
    const bridge = new WebAssembly.Instance(new WebAssembly.Module(BRIDGE), {
      h: { c: (ptr, len, reuse) => jit.compile(ptr, len, reuse >>> 0) },
    });
    x.lus_wasm_jit_host(x.__indirect_function_table.grow(1, bridge.exports.c));
    return jit;
  }

  constructor(exports, options) {
    this.memory = exports.memory;
    this.table = exports.__indirect_function_table;
    this.statsAddress = exports.lus_wasm_jit_stats?.();
    this.syncLimit = options.syncLimit ?? JIT_SYNC_LIMIT;
    this.onError = options.onError ?? null;
    this.entries = new Map();
    this.background = new Map();
    this.stats = {
      modules: 0,
      bytes: 0,
      compileMs: 0,
      instantiateMs: 0,
      deferred: 0,
      failed: 0,
    };
  }

  /** The counts that lus.wasm keeps itself. */
  runtimeStats() {
    if (!this.statsAddress) return null;
    const v = new Uint32Array(this.memory.buffer, this.statsAddress, 4);
    return { compiled: v[0], failed: v[1], deferred: v[2], bytes: v[3] };
  }

  /** The table entry `index` of lus.wasm, which a module imports. */
  entry(index) {
    let f = this.entries.get(index);
    if (f === undefined) {
      f = this.table.get(index);
      this.entries.set(index, f);
    }
    return f;
  }

  imports(module) {
    const t = {};
    for (const im of WebAssembly.Module.imports(module)) {
      if (im.module === "t") t[im.name] = this.entry(Number(im.name));
    }
    return { env: { memory: this.memory, table: this.table }, t };
  }

  install(module, reuse) {
    const start = now();
    const instance = new WebAssembly.Instance(module, this.imports(module));
    this.stats.instantiateMs += now() - start;
    this.stats.modules++;
    const f = instance.exports.f;
    if (reuse) {
      this.table.set(reuse, f);
      return reuse;
    }
    return this.table.grow(1, f);
  }

  /** The compile function that lus.wasm calls. */
  compile(ptr, len, reuse) {
    try {
      const bytes = new Uint8Array(this.memory.buffer, ptr, len).slice();
      this.stats.bytes += len;
      if (len > this.syncLimit) return this.compileInBackground(bytes, reuse);
      const start = now();
      let module;
      try {
        module = new WebAssembly.Module(bytes);
      } catch (error) {
        // Some hosts refuse to compile large modules synchronously.
        if (error instanceof RangeError) return this.compileInBackground(bytes, reuse);
        throw error;
      }
      this.stats.compileMs += now() - start;
      return this.install(module, reuse);
    } catch (error) {
      this.stats.failed++;
      this.onError?.(error);
      return 0;
    }
  }

  /**
   * Starts compiling `bytes` in the background and answers PENDING. The
   * function keeps running in the interpreter and asks again later, with
   * the same bytes, once it has run some more. A long-lived state, such
   * as the language server, then gets the compiled function on a later
   * request.
   */
  compileInBackground(bytes, reuse) {
    const key = fingerprint(bytes);
    const job = this.background.get(key);
    if (job && sameBytes(job.bytes, bytes)) {
      if (job.module) {
        this.background.delete(key);
        return this.install(job.module, reuse);
      }
      if (job.failed) {
        this.background.delete(key);
        this.stats.failed++;
        return 0;
      }
      return PENDING;
    }
    const entry = { bytes, module: null, failed: false };
    this.background.set(key, entry);
    this.stats.deferred++;
    const start = now();
    WebAssembly.compile(bytes).then(
      (module) => {
        this.stats.compileMs += now() - start;
        entry.module = module;
      },
      (error) => {
        entry.failed = true;
        this.onError?.(error);
      },
    );
    return PENDING;
  }
}

function fingerprint(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 0x01000193);
  return `${bytes.length}:${h >>> 0}`;
}

function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
