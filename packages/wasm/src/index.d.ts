/** An in-memory file system shared by every state of a `Lus` instance. */
export class MemFS {
  writeFile(path: string, contents: string | Uint8Array): void;
  readFile(path: string): Uint8Array;
  readFile(path: string, options: { encoding: "utf8" }): string;
  exists(path: string): boolean;
  readdir(path: string): string[];
  mkdir(path: string): void;
  remove(path: string): void;
  /** Writes every file of `files` below `prefix` (default "/"). */
  mount(files: Record<string, string | Uint8Array>, prefix?: string): void;
}

/** Thrown inside the host when a program calls `os.exit`. */
export class WasiExit extends Error {
  code: number;
}

/** A state handle: the address of a `lus_State` in linear memory. */
export type LusState = number;

export interface RunOptions {
  /** The chunk name used in messages. Defaults to "=(playground)". */
  chunkname?: string;
  /** Script arguments, passed as `...` and stored in `arg`. */
  args?: string[];
  /** Permissions granted by the host, like `lus -P`. */
  pledges?: string[];
  /** Bytes that `io.read` returns. */
  stdin?: string | Uint8Array;
  /** Files written to the file system before the run. */
  files?: Record<string, string | Uint8Array>;
  /** Stops capturing output after this many bytes. */
  maxOutputBytes?: number;
}

export interface RunResult {
  /** True when the program finished without error and exited with status 0. */
  ok: boolean;
  stdout: string;
  stderr: string;
  /** Standard output and standard error interleaved in write order. */
  output: string;
  /** The error message, or null. */
  error: string | null;
  /** The stack traceback of the error, or null. */
  traceback: string | null;
  /** 0, 1 after an error, the `os.exit` status, or 134 after a crash. */
  exitCode: number;
  /** True when output went past `maxOutputBytes`. */
  truncated: boolean;
}

export const MAX_LSP_FRAME_BYTES: number;
export const EXEC_OUTPUT_BYTES: number;

export interface JitOptions {
  /** Modules up to this many bytes compile synchronously. Larger ones compile in the background. */
  syncLimit?: number;
  /** Called with every error of compiling or instantiating a module. */
  onError?: (error: unknown) => void;
}

/** The host side of the WebAssembly JIT, which compiles and installs the modules lus.wasm emits. */
export class WasmJit {
  /** Registers a JIT host with an instance of lus.wasm. Returns null when the module has no JIT. */
  static attach(instance: WebAssembly.Instance, options?: JitOptions): WasmJit | null;
  /** What the host did: modules installed, bytes received, and the time spent compiling and instantiating them. */
  readonly stats: {
    modules: number;
    bytes: number;
    compileMs: number;
    instantiateMs: number;
    deferred: number;
    failed: number;
  };
  /** The counts lus.wasm keeps: functions compiled, modules that failed or were deferred, and bytes emitted. */
  runtimeStats(): { compiled: number; failed: number; deferred: number; bytes: number } | null;
}

export class Lus {
  static load(
    source: BufferSource | WebAssembly.Module | Response | URL | string,
    options?: { fs?: MemFS; env?: Record<string, string>; jit?: false | JitOptions },
  ): Promise<Lus>;

  /**
   * The JIT host of the current instance, or null when the options turned
   * it off or the module has no JIT. `LUS_JIT` in `env` sets the policy
   * of each state, as it does for the native runtime.
   */
  readonly jit: WasmJit | null;

  readonly fs: MemFS;
  /**
   * True after `os.exit` or a trap ended the WebAssembly instance. The
   * next call starts a fresh instance, and every earlier state is invalid.
   */
  readonly dead: boolean;
  /** Environment variables visible to `os.getenv` (with the `env` pledge). */
  env: Record<string, string>;

  /** Runs a whole program in a fresh state. */
  run(source: string, options?: RunOptions): RunResult;

  /** Creates a long-lived state with the standard libraries open. */
  create(options?: { pledges?: string[] }): LusState;
  /** Closes a state. */
  destroy(state: LusState): void;
  /** Runs playground input in `state` and returns its output. */
  execute(state: LusState, code: string): string;
  /** Loads the language server into `state`. Returns "" on success. */
  loadLsp(state: LusState, source?: string): string;
  /** Dispatches one JSON-RPC body and returns the framed responses. */
  handleMessage(state: LusState, json: string): string;
  /** Dispatches one complete Content-Length frame. */
  handleFrame(state: LusState, frame: string): string;
  /** Reads /lus-language/wasm.lus from the file system. */
  getLspSource(): string;

  /** The raw exports of lus.wasm: the C API of lus.h and the lus_wasm_* helpers. */
  readonly exports: WebAssembly.Exports & Record<string, (...args: never[]) => unknown>;
}
