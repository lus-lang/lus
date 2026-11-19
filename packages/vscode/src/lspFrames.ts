export const MAX_LSP_FRAME_BYTES = 16 * 1024 * 1024;
export const MAX_LSP_HEADER_BYTES = 8 * 1024;
export const MAX_LSP_DISPATCH_OUTPUT_BYTES =
  MAX_LSP_FRAME_BYTES + MAX_LSP_HEADER_BYTES;

const HEADER_TERMINATOR = new Uint8Array([13, 10, 13, 10]);
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export class LspFrameError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LspFrameError";
  }
}

function bytesOf(raw: string | Uint8Array): Uint8Array {
  return typeof raw === "string" ? utf8Encoder.encode(raw) : raw;
}

function findHeaderEnd(bytes: Uint8Array, start: number): number {
  const last = Math.min(
    bytes.length - HEADER_TERMINATOR.length,
    start + MAX_LSP_HEADER_BYTES,
  );
  for (let index = start; index <= last; index += 1) {
    let matched = true;
    for (let offset = 0; offset < HEADER_TERMINATOR.length; offset += 1) {
      if (bytes[index + offset] !== HEADER_TERMINATOR[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return index;
    }
  }
  throw new LspFrameError("Invalid or oversized JSON-RPC header");
}

function decodeAscii(bytes: Uint8Array): string {
  for (const byte of bytes) {
    if (byte > 0x7f) {
      throw new LspFrameError("JSON-RPC headers must be ASCII");
    }
  }
  return String.fromCharCode(...bytes);
}

function parseHeaders(bytes: Uint8Array): number {
  const headerText = decodeAscii(bytes);
  const headers = new Map<string, string>();

  for (const line of headerText.split("\r\n")) {
    const match = /^([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*(.*?)[ \t]*$/.exec(
      line,
    );
    if (!match) {
      throw new LspFrameError("Malformed JSON-RPC header");
    }

    const name = match[1].toLowerCase();
    if (headers.has(name)) {
      throw new LspFrameError("Duplicate JSON-RPC header");
    }
    headers.set(name, match[2]);
  }

  const rawLength = headers.get("content-length");
  if (rawLength === undefined || !/^(0|[1-9][0-9]*)$/.test(rawLength)) {
    throw new LspFrameError("Invalid Content-Length header");
  }

  const contentLength = Number(rawLength);
  if (!Number.isSafeInteger(contentLength) || contentLength > MAX_LSP_FRAME_BYTES) {
    throw new LspFrameError("JSON-RPC frame exceeds the 16 MiB limit");
  }

  const contentType = headers.get("content-type");
  if (
    contentType !== undefined &&
    !/^application\/vscode-jsonrpc;[ \t]*charset=utf-8$/i.test(contentType)
  ) {
    throw new LspFrameError("JSON-RPC content must use UTF-8");
  }

  return contentLength;
}

export function parseLspFrames(raw: string | Uint8Array): unknown[] {
  const bytes = bytesOf(raw);
  const messages: unknown[] = [];
  let position = 0;

  while (position < bytes.length) {
    const headerEnd = findHeaderEnd(bytes, position);
    const contentLength = parseHeaders(bytes.subarray(position, headerEnd));
    const bodyStart = headerEnd + HEADER_TERMINATOR.length;
    const bodyEnd = bodyStart + contentLength;
    if (bodyEnd > bytes.length) {
      throw new LspFrameError("Truncated JSON-RPC frame");
    }

    let body: string;
    try {
      body = utf8Decoder.decode(bytes.subarray(bodyStart, bodyEnd));
    } catch {
      throw new LspFrameError("JSON-RPC body is not valid UTF-8");
    }

    let message: unknown;
    try {
      message = JSON.parse(body);
    } catch {
      throw new LspFrameError("JSON-RPC body is not valid JSON");
    }
    if (message === null || typeof message !== "object" || Array.isArray(message)) {
      throw new LspFrameError("JSON-RPC body must contain an object");
    }

    messages.push(message);
    position = bodyEnd;
  }

  return messages;
}

export function serializeJsonRpcMessage(message: unknown): string {
  const json = JSON.stringify(message);
  if (json === undefined) {
    throw new LspFrameError("JSON-RPC message cannot be serialized");
  }
  if (utf8Encoder.encode(json).byteLength > MAX_LSP_FRAME_BYTES) {
    throw new LspFrameError("JSON-RPC message exceeds the 16 MiB limit");
  }
  return json;
}
