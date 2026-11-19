import {
  AbstractMessageReader,
  AbstractMessageWriter,
  DataCallback,
  Disposable,
  Emitter,
  Message,
  MessageReader,
  MessageTransports,
  MessageWriter,
} from "vscode-languageclient/node";
import { LusWasm } from "./wasm";
import { parseLspFrames, serializeJsonRpcMessage } from "./lspFrames";

class WasmMessageReader extends AbstractMessageReader implements MessageReader {
  private readonly messageEmitter = new Emitter<Message>();
  private listening = false;

  listen(callback: DataCallback): Disposable {
    if (this.listening) {
      throw new Error("The WASM message reader is already listening");
    }
    this.listening = true;
    return this.messageEmitter.event(callback);
  }

  push(message: Message): void {
    this.messageEmitter.fire(message);
  }

  override dispose(): void {
    this.messageEmitter.dispose();
    super.dispose();
  }
}

export class WasmDispatcher {
  private tail: Promise<void> = Promise.resolve();

  constructor(
    private readonly wasm: LusWasm,
    private readonly state: number,
  ) {}

  dispatch(message: unknown): Promise<Message[]> {
    const operation = this.tail.then(() => this.dispatchNow(message));
    this.tail = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private dispatchNow(message: unknown): Message[] {
    const json = serializeJsonRpcMessage(message);
    const rawOutput = this.wasm.handleMessage(this.state, json);
    if (rawOutput.length === 0) {
      return [];
    }
    return parseLspFrames(rawOutput) as Message[];
  }
}

class WasmMessageWriter extends AbstractMessageWriter implements MessageWriter {
  private ended = false;

  constructor(
    private readonly dispatcher: WasmDispatcher,
    private readonly reader: WasmMessageReader,
  ) {
    super();
  }

  async write(message: Message): Promise<void> {
    if (this.ended) {
      const error = new Error("The WASM message writer is closed");
      this.fireError(error, message);
      throw error;
    }

    try {
      const responses = await this.dispatcher.dispatch(message);
      for (const response of responses) {
        this.reader.push(response);
      }
    } catch (cause) {
      const error =
        cause instanceof Error ? cause : new Error("WASM JSON-RPC dispatch failed");
      this.fireError(error, message);
      throw error;
    }
  }

  end(): void {
    if (!this.ended) {
      this.ended = true;
      this.fireClose();
    }
  }
}

export function createWasmTransports(
  dispatcher: WasmDispatcher,
): MessageTransports {
  const reader = new WasmMessageReader();
  const writer = new WasmMessageWriter(dispatcher, reader);
  return { reader, writer };
}
