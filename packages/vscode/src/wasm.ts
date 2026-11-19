import * as path from "node:path";
import type * as vscode from "vscode";
import type { Lus } from "lus-wasm" with { "resolution-mode": "import" };

/**
 * The Lus runtime of the extension. It runs the packaged `wasm/lus.wasm`
 * through the lus-wasm host, which esbuild bundles into the extension,
 * and serves the language server from the packaged `language-server`
 * directory, mounted at /lus-language in the host's file system.
 */
export class LusWasm {
  private constructor(private readonly lus: Lus) {}

  static async load(context: vscode.ExtensionContext): Promise<LusWasm> {
    // The bundle is CommonJS, where lus-wasm cannot locate its own files,
    // so both paths are explicit.
    const { loadLus, mountLanguageServer } = await import("lus-wasm");
    const lus = await loadLus(
      path.join(context.extensionPath, "wasm", "lus.wasm"),
    );
    await mountLanguageServer(
      lus,
      path.join(context.extensionPath, "language-server"),
    );
    return new LusWasm(lus);
  }

  create(): number {
    return this.lus.create();
  }

  execute(state: number, code: string): string {
    return this.lus.execute(state, code);
  }

  loadLsp(state: number, source: string): string {
    return this.lus.loadLsp(state, source);
  }

  handleMessage(state: number, json: string): string {
    return this.lus.handleMessage(state, json);
  }

  destroy(state: number): void {
    this.lus.destroy(state);
  }

  getLspSource(): string {
    try {
      return this.lus.getLspSource();
    } catch {
      throw new Error("The embedded Lus language server is unavailable");
    }
  }
}
