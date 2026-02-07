import {
  Message,
  MessageTransports,
  DataCallback,
  Disposable,
  Event,
  Emitter,
  AbstractMessageReader,
  AbstractMessageWriter,
  MessageReader,
  MessageWriter,
} from "vscode-languageclient";
import { LusWasm } from "./wasm";

/**
 * Parse Content-Length-delimited LSP messages from raw output.
 * The WASM host captures all io.write output which may contain
 * multiple LSP messages (e.g., response + publishDiagnostics notification).
 */
function parseLspMessages(raw: string): any[] {
  const messages: any[] = [];
  let pos = 0;

  while (pos < raw.length) {
    // Find Content-Length header
    const headerMatch = raw.substring(pos).match(/Content-Length:\s*(\d+)\r?\n\r?\n/);
    if (!headerMatch) break;

    const contentLength = parseInt(headerMatch[1], 10);
    const bodyStart = pos + headerMatch[0].length;
    const bodyEnd = bodyStart + contentLength;

    if (bodyEnd > raw.length) break;

    const body = raw.substring(bodyStart, bodyEnd);
    try {
      messages.push(JSON.parse(body));
    } catch {
      // Skip malformed messages
    }

    pos = bodyEnd;
  }

  return messages;
}

/**
 * MessageReader that receives messages pushed from the WASM handler.
 */
class WasmMessageReader extends AbstractMessageReader implements MessageReader {
  private messageEmitter = new Emitter<Message>();
  private _onError = new Emitter<Error>();
  private _onClose = new Emitter<void>();

  constructor() {
    super();
  }

  get onError(): Event<Error> {
    return this._onError.event;
  }
  get onClose(): Event<void> {
    return this._onClose.event;
  }

  listen(callback: DataCallback): Disposable {
    return this.messageEmitter.event(callback);
  }

  /** Push a parsed message from the WASM output */
  push(message: Message): void {
    this.messageEmitter.fire(message);
  }

  dispose(): void {
    super.dispose();
    this.messageEmitter.dispose();
    this._onError.dispose();
    this._onClose.dispose();
  }
}

/**
 * MessageWriter that sends messages to the WASM handler.
 */
class WasmMessageWriter extends AbstractMessageWriter implements MessageWriter {
  private _onError = new Emitter<[Error, Message | undefined, number | undefined]>();
  private _onClose = new Emitter<void>();

  private wasm: LusWasm;
  private state: number;
  private reader: WasmMessageReader;

  constructor(wasm: LusWasm, state: number, reader: WasmMessageReader) {
    super();
    this.wasm = wasm;
    this.state = state;
    this.reader = reader;
  }

  get onError(): Event<[Error, Message | undefined, number | undefined]> {
    return this._onError.event;
  }
  get onClose(): Event<void> {
    return this._onClose.event;
  }

  async write(msg: Message): Promise<void> {
    try {
      const json = JSON.stringify(msg);
      const rawOutput = this.wasm.handleMessage(this.state, json);

      if (rawOutput && rawOutput.length > 0) {
        // Check if it's an error (doesn't start with Content-Length)
        if (!rawOutput.startsWith("Content-Length:")) {
          // Likely an error string -- log it
          console.error("[lus-language]", rawOutput);
          return;
        }

        // Parse all LSP messages from the output
        const messages = parseLspMessages(rawOutput);
        for (const message of messages) {
          this.reader.push(message as Message);
        }
      }
    } catch (err) {
      this._onError.fire([
        err instanceof Error ? err : new Error(String(err)),
        msg,
        undefined,
      ]);
    }
  }

  end(): void {}

  dispose(): void {
    super.dispose();
    this._onError.dispose();
    this._onClose.dispose();
  }
}

/**
 * Create MessageTransports that communicate with the Lus WASM LSP.
 */
export function createWasmTransports(
  wasm: LusWasm,
  state: number,
): MessageTransports {
  const reader = new WasmMessageReader();
  const writer = new WasmMessageWriter(wasm, state, reader);

  return { reader, writer };
}
