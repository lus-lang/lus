import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions } from "vscode-languageclient";
import { LusWasm } from "./wasm";
import { createWasmTransports } from "./lspTransport";

let client: LanguageClient | undefined;
let lusWasm: LusWasm | undefined;
let lusState: number | undefined;

export async function activate(
  context: vscode.ExtensionContext,
): Promise<void> {
  const outputChannel = vscode.window.createOutputChannel("Lus Language Server");
  outputChannel.appendLine("Activating Lus extension...");

  try {
    // Load the WASM module
    lusWasm = await LusWasm.load(context);
    outputChannel.appendLine("WASM module loaded.");

    // Create a Lus state
    lusState = lusWasm.create();
    if (!lusState) {
      outputChannel.appendLine("ERROR: Failed to create Lus state.");
      return;
    }
    outputChannel.appendLine("Lus state created.");

    // Load the LSP server code
    const lspSource = lusWasm.getLspSource(context);
    outputChannel.appendLine(`LSP source loaded (${lspSource.length} bytes).`);
    const loadError = lusWasm.loadLsp(lusState, lspSource);
    if (loadError && loadError.length > 0) {
      outputChannel.appendLine(`ERROR: Failed to load LSP server:`);
      outputChannel.appendLine(loadError);
      return;
    }
    outputChannel.appendLine("LSP server loaded.");

    // Capture references for the closure
    const wasm = lusWasm;
    const state = lusState;

    // Server options: a function that returns message transports
    const serverOptions = () => {
      const transports = createWasmTransports(wasm, state);
      return Promise.resolve(transports);
    };

    // Client options
    const clientOptions: LanguageClientOptions = {
      documentSelector: [{ scheme: "file", language: "lus" }],
      outputChannel,
      synchronize: {
        fileEvents: vscode.workspace.createFileSystemWatcher("**/*.lus"),
      },
    };

    client = new LanguageClient(
      "lus",
      "Lus Language Server",
      serverOptions,
      clientOptions,
    );

    // Start the client
    await client.start();
    outputChannel.appendLine("Language client started.");
  } catch (err) {
    outputChannel.appendLine(
      `ERROR: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
  if (lusWasm && lusState) {
    lusWasm.destroy(lusState);
    lusState = undefined;
  }
  lusWasm = undefined;
}
