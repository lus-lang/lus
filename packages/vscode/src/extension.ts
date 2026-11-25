import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
} from "vscode-languageclient/node";
import { registerAtmosphereCompletion } from "./atmosphere";
import { registerDebugger } from "./debugAdapter";
import { registerTesting } from "./testing";
import {
  createWasmTransports,
  WasmDispatcher,
} from "./lspTransport";
import { LusWasm } from "./wasm";
import { WorkspaceMirror } from "./workspaceMirror";

const MAX_LOG_LINES = 128;
const MAX_LOG_LINE_LENGTH = 512;

class LifecycleLog {
  private lines = 0;

  constructor(private readonly channel: vscode.OutputChannel) {}

  event(message: string): void {
    if (this.lines >= MAX_LOG_LINES) {
      if (this.lines === MAX_LOG_LINES) {
        this.channel.appendLine("Lifecycle log limit reached.");
        this.lines += 1;
      }
      return;
    }
    const singleLine = message.replace(/[\r\n]+/g, " ");
    this.channel.appendLine(singleLine.slice(0, MAX_LOG_LINE_LENGTH));
    this.lines += 1;
  }

  failure(stage: string, cause: unknown): void {
    const kind = cause instanceof Error ? cause.name : "Error";
    this.event(`${stage} failed (${kind}).`);
  }
}

class ExtensionSession {
  constructor(
    private readonly client: LanguageClient,
    private readonly mirror: WorkspaceMirror,
    private readonly wasm: LusWasm,
    private readonly state: number,
    private readonly outputChannel: vscode.OutputChannel,
  ) {}

  async stop(): Promise<void> {
    let stopError: unknown;
    try {
      await this.mirror.shutdown();
    } catch (cause) {
      stopError = cause;
    }
    try {
      await this.client.stop();
    } catch (cause) {
      stopError ??= cause;
    }
    try {
      this.wasm.destroy(this.state);
    } finally {
      this.outputChannel.dispose();
    }
    if (stopError) {
      throw stopError;
    }
  }
}

let session: ExtensionSession | undefined;
let operationTail: Promise<void> = Promise.resolve();
let extensionContext: vscode.ExtensionContext | undefined;
let lifecycleLog: LifecycleLog | undefined;

function serialize(operation: () => Promise<void>): Promise<void> {
  const result = operationTail.then(operation);
  operationTail = result.catch(() => undefined);
  return result;
}

async function createSession(
  context: vscode.ExtensionContext,
  outputChannel: vscode.OutputChannel,
  log: LifecycleLog,
): Promise<ExtensionSession> {
  let wasm: LusWasm | undefined;
  let state: number | undefined;
  let mirror: WorkspaceMirror | undefined;
  let client: LanguageClient | undefined;

  try {
    log.event("Loading the Lus runtime.");
    wasm = await LusWasm.load(context);
    state = wasm.create();
    if (!state) {
      throw new Error("The Lus runtime could not create a state");
    }

    const loadError = wasm.loadLsp(state, wasm.getLspSource());
    if (loadError.length > 0) {
      throw new Error("The embedded Lus language server could not be loaded");
    }

    const dispatcher = new WasmDispatcher(wasm, state);
    mirror = new WorkspaceMirror((error) => {
      log.failure("Workspace mirror update", error);
    });
    const seedSender = async (method: string, params: unknown) => {
      const responses = await dispatcher.dispatch({
        jsonrpc: "2.0",
        method,
        params,
      });
      if (responses.length > 0) {
        throw new Error("The language server replied before initialization");
      }
    };

    log.event("Mirroring workspace source files.");
    await mirror.seed(seedSender);

    const serverOptions = async () => createWasmTransports(dispatcher);
    const clientOptions: LanguageClientOptions = {
      documentSelector: [
        { language: "lus" },
        { language: "lua", pattern: "**/*.lua" },
      ],
      outputChannel,
      connectionOptions: {
        maxRestartCount: 0,
      },
    };
    client = new LanguageClient(
      "lus",
      "Lus Language Server",
      serverOptions,
      clientOptions,
    );

    log.event("Starting the Lus language client.");
    await client.start();
    await mirror.activate((method, params) =>
      client!.sendNotification(method, params),
    );
    log.event("The Lus language client is ready.");
    return new ExtensionSession(client, mirror, wasm, state, outputChannel);
  } catch (cause) {
    mirror?.dispose();
    if (client) {
      try {
        await client.stop();
      } catch {
        // The original startup failure is the actionable error.
      }
    }
    if (wasm && state) {
      wasm.destroy(state);
    }
    outputChannel.dispose();
    throw cause;
  }
}

async function replaceSession(): Promise<void> {
  if (!extensionContext || !lifecycleLog) {
    throw new Error("The Lus extension is not active");
  }

  const previous = session;
  session = undefined;
  if (previous) {
    lifecycleLog.event("Stopping the previous language client.");
    await previous.stop();
  }

  const outputChannel = vscode.window.createOutputChannel(
    "Lus Language Server",
  );
  extensionContext.subscriptions.push(outputChannel);
  session = await createSession(extensionContext, outputChannel, lifecycleLog);
}

async function startWithRetry(): Promise<void> {
  for (;;) {
    try {
      await serialize(replaceSession);
      return;
    } catch (cause) {
      lifecycleLog?.failure("Language server startup", cause);
      const action = await vscode.window.showErrorMessage(
        "The Lus language server failed to start.",
        "Retry",
      );
      if (action !== "Retry") {
        throw cause;
      }
    }
  }
}

export async function activate(
  context: vscode.ExtensionContext,
): Promise<void> {
  extensionContext = context;
  const lifecycleChannel = vscode.window.createOutputChannel("Lus");
  context.subscriptions.push(lifecycleChannel);
  lifecycleLog = new LifecycleLog(lifecycleChannel);
  registerDebugger(context);
  registerTesting(context);
  registerAtmosphereCompletion(context);

  context.subscriptions.push(
    vscode.commands.registerCommand("lus.restartLanguageServer", async () => {
      try {
        await serialize(replaceSession);
      } catch (cause) {
        lifecycleLog?.failure("Language server restart", cause);
        const action = await vscode.window.showErrorMessage(
          "The Lus language server could not be restarted.",
          "Retry",
        );
        if (action === "Retry") {
          await startWithRetry();
        }
      }
    }),
  );

  await startWithRetry();
}

export async function deactivate(): Promise<void> {
  await serialize(async () => {
    const current = session;
    session = undefined;
    if (current) {
      await current.stop();
    }
    extensionContext = undefined;
    lifecycleLog = undefined;
  });
}
