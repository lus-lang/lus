import * as path from "node:path";
import { pathToFileURL } from "node:url";
import * as vscode from "vscode";
import { packagedWasmAsset } from "./wasmAsset";
import {
  callWasmUtf8,
  dispatchJsonRpcUtf8,
  WasmByteDispatcher,
  WasmUtf8Module,
} from "./wasmUtf8";

interface EmscriptenFileSystem {
  readFile(path: string, options: { encoding: "utf8" }): string;
}

interface EmscriptenModule extends WasmUtf8Module {
  FS: EmscriptenFileSystem;
  cwrap(
    name: string,
    returnType: "number" | "string" | null,
    argumentTypes: string[],
  ): (...args: unknown[]) => unknown;
}

type ModuleFactory = (options: {
  locateFile(file: string): string;
}) => Promise<EmscriptenModule>;

export class LusWasm {
  private readonly createState: () => number;
  private readonly executeSourceBytes: WasmByteDispatcher;
  private readonly loadLanguageServerBytes: WasmByteDispatcher;
  private readonly dispatchMessageBytes: WasmByteDispatcher;
  private readonly outputLength: (state: number) => number;
  private readonly destroyState: (state: number) => void;

  private constructor(private readonly module: EmscriptenModule) {
    this.createState = module.cwrap("lus_create", "number", []) as () => number;
    this.executeSourceBytes = module.cwrap(
      "lus_execute_bytes",
      "number",
      ["number", "number", "number"],
    ) as WasmByteDispatcher;
    this.loadLanguageServerBytes = module.cwrap(
      "lus_load_lsp_bytes",
      "number",
      ["number", "number", "number"],
    ) as WasmByteDispatcher;
    this.dispatchMessageBytes = module.cwrap(
      "lus_handle_message_bytes",
      "number",
      ["number", "number", "number"],
    ) as (
      state: number,
      inputPointer: number,
      inputBytes: number,
    ) => number;
    this.outputLength = module.cwrap("lus_output_length", "number", [
      "number",
    ]) as (state: number) => number;
    this.destroyState = module.cwrap("lus_destroy", null, ["number"]) as (
      state: number,
    ) => void;
  }

  static async load(context: vscode.ExtensionContext): Promise<LusWasm> {
    const wasmDirectory = path.join(context.extensionPath, "wasm");
    const modulePath = path.join(wasmDirectory, "lus.mjs");
    const moduleUrl = pathToFileURL(modulePath).href;
    const imported = (await import(moduleUrl)) as {
      default?: ModuleFactory;
    };
    if (typeof imported.default !== "function") {
      throw new Error("The Lus WASM module does not export a module factory");
    }

    const module = await imported.default({
      locateFile: (file: string) =>
        pathToFileURL(path.join(wasmDirectory, packagedWasmAsset(file))).href,
    });
    return new LusWasm(module);
  }

  create(): number {
    return this.createState();
  }

  execute(state: number, code: string): string {
    return callWasmUtf8(
      this.module,
      this.executeSourceBytes,
      this.outputLength,
      state,
      code,
      { label: "WASM source" },
    );
  }

  loadLsp(state: number, source: string): string {
    return callWasmUtf8(
      this.module,
      this.loadLanguageServerBytes,
      this.outputLength,
      state,
      source,
      { label: "WASM language server" },
    );
  }

  handleMessage(state: number, json: string): string {
    return dispatchJsonRpcUtf8(
      this.module,
      this.dispatchMessageBytes,
      this.outputLength,
      state,
      json,
    );
  }

  destroy(state: number): void {
    this.destroyState(state);
  }

  getLspSource(): string {
    try {
      return this.module.FS.readFile("/lus-language/wasm.lus", {
        encoding: "utf8",
      });
    } catch {
      throw new Error("The embedded Lus language server is unavailable");
    }
  }
}
