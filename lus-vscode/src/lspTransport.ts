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
 *
 * Content-Length is in bytes (UTF-8), but JavaScript strings are UTF-16.
 * We use TextEncoder to find the correct character boundary for each body.
 */
function parseLspMessages(raw: string): any[] {
  const messages: any[] = [];
  const encoder = new TextEncoder();
  let pos = 0;

  while (pos < raw.length) {
    // Find Content-Length header
    const headerMatch = raw.substring(pos).match(/Content-Length:\s*(\d+)\r?\n\r?\n/);
    if (!headerMatch) break;

    const contentLengthBytes = parseInt(headerMatch[1], 10);
    const bodyStartChar = pos + headerMatch[0].length;

    // Walk characters from bodyStart, counting UTF-8 bytes, until we've
    // consumed contentLengthBytes. This correctly handles multi-byte chars.
    let bytesConsumed = 0;
    let bodyEndChar = bodyStartChar;
    while (bodyEndChar < raw.length && bytesConsumed < contentLengthBytes) {
      const code = raw.charCodeAt(bodyEndChar);
      if (code <= 0x7f) {
        bytesConsumed += 1;
      } else if (code <= 0x7ff) {
        bytesConsumed += 2;
      } else if (code >= 0xd800 && code <= 0xdbff) {
        // High surrogate — together with the next low surrogate = 4 UTF-8 bytes
        bytesConsumed += 4;
        bodyEndChar++; // skip low surrogate
      } else {
        bytesConsumed += 3;
      }
      bodyEndChar++;
    }

    if (bytesConsumed < contentLengthBytes) break;

    const body = raw.substring(bodyStartChar, bodyEndChar);
    try {
      messages.push(JSON.parse(body));
    } catch {
      // Skip malformed messages
    }

    pos = bodyEndChar;
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
      // Log document-affecting requests
      const method = (msg as any).method;
      if (method === "textDocument/didOpen") {
        const text = (msg as any).params?.textDocument?.text ?? "";
        const lines = text.split("\n");
        console.log(`[lus-lsp] didOpen: ${lines.length} lines, ${text.length} chars`);
      } else if (method === "textDocument/didChange") {
        const changes = (msg as any).params?.contentChanges;
        if (changes) {
          const ver = (msg as any).params?.textDocument?.version ?? "?";
          console.log(`[lus-lsp] didChange v${ver}: ${changes.length} change(s)`);
          for (let ci = 0; ci < changes.length; ci++) {
            const c = changes[ci];
            if (c.range) {
              const esc = (c.text ?? "").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
              console.log(`  [${ci}] L${c.range.start.line + 1}:${c.range.start.character + 1}–L${c.range.end.line + 1}:${c.range.end.character + 1} text="${esc.length > 60 ? esc.slice(0, 60) + "..." : esc}"`);
            } else {
              const lines = (c.text ?? "").split("\n");
              console.log(`  [${ci}] full: ${lines.length} lines, ${(c.text ?? "").length} chars`);
            }
          }
        }
      }
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
          // Log semantic token responses for debugging
          if (
            (message as any).result?.data &&
            Array.isArray((message as any).result.data)
          ) {
            const data = (message as any).result.data as number[];
            const typeNames = [
              "variable", "parameter", "function", "method",
              "keyword", "string", "number", "comment",
              "operator", "property", "enum", "enumMember",
            ];
            console.log(
              `[lus-semtok] ${data.length / 5} tokens, raw data length: ${data.length}`,
            );
            let prevLine = 0,
              prevCol = 0;
            for (let i = 0; i < data.length; i += 5) {
              const dLine = data[i],
                dCol = data[i + 1],
                len = data[i + 2],
                type = data[i + 3],
                mods = data[i + 4];
              const absLine = prevLine + dLine;
              const absCol = dLine === 0 ? prevCol + dCol : dCol;
              prevLine = absLine;
              prevCol = absCol;
              const tname = typeNames[type] || `type${type}`;
              console.log(
                `  [${i / 5}] L${absLine + 1}:${absCol + 1} len=${len} ${tname} mods=${mods}`,
              );
            }
          }
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
