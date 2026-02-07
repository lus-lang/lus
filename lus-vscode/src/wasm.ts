import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";

/**
 * Wrapper around the Lus WASM module.
 * Provides a TypeScript API for creating Lus states and running the LSP.
 */
export class LusWasm {
  private module: any;
  private cwrap: any;

  private _create: () => number;
  private _execute: (state: number, code: string) => string;
  private _loadLsp: (state: number, source: string) => string;
  private _handleMessage: (state: number, json: string) => string;
  private _destroy: (state: number) => void;

  private constructor(mod: any) {
    this.module = mod;
    this.cwrap = mod.cwrap;

    this._create = this.cwrap("lus_create", "number", []);
    this._execute = this.cwrap("lus_execute", "string", ["number", "string"]);
    this._loadLsp = this.cwrap("lus_load_lsp", "string", [
      "number",
      "string",
    ]);
    this._handleMessage = this.cwrap("lus_handle_message", "string", [
      "number",
      "string",
    ]);
    this._destroy = this.cwrap("lus_destroy", null, ["number"]);
  }

  /**
   * Load the WASM module from the extension's wasm/ directory.
   */
  static async load(context: vscode.ExtensionContext): Promise<LusWasm> {
    const wasmDir = path.join(context.extensionPath, "wasm");
    const jsPath = path.join(wasmDir, "lus.js");

    // Dynamic import of the Emscripten-generated ESM module
    const { default: createModule } = await import(jsPath);
    const mod = await createModule({
      // Emscripten configuration
      locateFile: (file: string) => path.join(wasmDir, file),
    });

    return new LusWasm(mod);
  }

  /**
   * Create a new Lus state.
   */
  create(): number {
    return this._create();
  }

  /**
   * Execute a Lus code string. Returns the output.
   */
  execute(state: number, code: string): string {
    return this._execute(state, code);
  }

  /**
   * Load the language server into a Lus state.
   * The source should be the content of wasm.lus.
   * Returns empty string on success, or error message on failure.
   */
  loadLsp(state: number, source: string): string {
    return this._loadLsp(state, source);
  }

  /**
   * Handle a single LSP JSON-RPC message.
   * Returns the raw output (Content-Length-delimited LSP messages).
   */
  handleMessage(state: number, json: string): string {
    return this._handleMessage(state, json);
  }

  /**
   * Destroy a Lus state.
   */
  destroy(state: number): void {
    this._destroy(state);
  }

  /**
   * Read the embedded LSP source from the WASM virtual filesystem.
   * Falls back to reading from disk if not embedded.
   */
  getLspSource(context: vscode.ExtensionContext): string {
    // Try reading wasm.lus from the language server directory
    const candidates = [
      path.join(context.extensionPath, "..", "lus-language", "wasm.lus"),
      path.join(context.extensionPath, "lus-language", "wasm.lus"),
    ];

    for (const p of candidates) {
      if (fs.existsSync(p)) {
        return fs.readFileSync(p, "utf-8");
      }
    }

    throw new Error(
      "Could not find lus-language/wasm.lus. Ensure the language server files are available.",
    );
  }
}
