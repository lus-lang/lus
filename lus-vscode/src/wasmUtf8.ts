import {
  MAX_LSP_DISPATCH_OUTPUT_BYTES,
  MAX_LSP_FRAME_BYTES,
} from "./lspFrames";

export interface WasmUtf8Module {
  HEAPU8: Uint8Array;
  _free(pointer: number): void;
  _malloc(size: number): number;
  lengthBytesUTF8(value: string): number;
  stringToUTF8(value: string, pointer: number, maxBytesToWrite: number): number;
}

export type WasmByteDispatcher = (
  state: number,
  inputPointer: number,
  inputBytes: number,
) => number;

const MAX_WASM32_INPUT_BYTES = 0xffff_fffe;
const MAX_WASM32_OUTPUT_BYTES = 0xffff_ffff;
const wasmOutputDecoder = new TextDecoder("utf-8", { fatal: true });

function decodeWasmOutput(
  module: WasmUtf8Module,
  pointer: number,
  byteLength: number,
  label: string,
): string {
  const heap = module.HEAPU8;
  if (
    !(heap instanceof Uint8Array) ||
    !Number.isSafeInteger(pointer) ||
    pointer < 0 ||
    pointer > heap.byteLength ||
    byteLength > heap.byteLength - pointer
  ) {
    throw new Error(`${label} output is outside WASM linear memory`);
  }
  try {
    return wasmOutputDecoder.decode(heap.subarray(pointer, pointer + byteLength));
  } catch {
    throw new Error(`${label} output is not valid UTF-8`);
  }
}

interface WasmUtf8CallOptions {
  label: string;
  maxInputBytes?: number;
  maxOutputBytes?: number;
  inputSizeError?: string;
  outputSizeError?: string;
}

export function callWasmUtf8(
  module: WasmUtf8Module,
  call: WasmByteDispatcher,
  outputLength: (state: number) => number,
  state: number,
  input: string,
  options: WasmUtf8CallOptions,
): string {
  const inputBytes = module.lengthBytesUTF8(input);
  const maxInputBytes = options.maxInputBytes ?? MAX_WASM32_INPUT_BYTES;
  if (
    !Number.isSafeInteger(inputBytes) ||
    inputBytes < 0 ||
    inputBytes > maxInputBytes ||
    inputBytes > MAX_WASM32_INPUT_BYTES
  ) {
    throw new Error(
      options.inputSizeError ??
        `${options.label} input size is not representable in wasm32`,
    );
  }

  const allocationBytes = inputBytes + 1;
  const inputPointer = module._malloc(allocationBytes);
  if (!Number.isSafeInteger(inputPointer) || inputPointer <= 0) {
    throw new Error(`${options.label} input allocation failed`);
  }

  try {
    const written = module.stringToUTF8(
      input,
      inputPointer,
      allocationBytes,
    );
    if (written !== inputBytes) {
      throw new Error(`${options.label} input encoding failed`);
    }

    const outputPointer = call(state, inputPointer, inputBytes);
    const outputBytes = outputLength(state);
    const maxOutputBytes = options.maxOutputBytes ?? MAX_WASM32_OUTPUT_BYTES;
    if (
      !Number.isSafeInteger(outputBytes) ||
      outputBytes < 0 ||
      outputBytes > maxOutputBytes ||
      outputBytes > MAX_WASM32_OUTPUT_BYTES
    ) {
      throw new Error(
        options.outputSizeError ??
          `${options.label} output size is not representable in wasm32`,
      );
    }
    if (outputBytes === 0) {
      return "";
    }
    if (!Number.isSafeInteger(outputPointer) || outputPointer <= 0) {
      throw new Error(`${options.label} output is unavailable`);
    }
    return decodeWasmOutput(
      module,
      outputPointer,
      outputBytes,
      options.label,
    );
  } finally {
    module._free(inputPointer);
  }
}

export function dispatchJsonRpcUtf8(
  module: WasmUtf8Module,
  dispatch: WasmByteDispatcher,
  outputLength: (state: number) => number,
  state: number,
  json: string,
): string {
  const inputBytes = module.lengthBytesUTF8(json);
  if (
    !Number.isSafeInteger(inputBytes) ||
    inputBytes < 0 ||
    inputBytes > MAX_LSP_FRAME_BYTES
  ) {
    throw new Error("WASM JSON-RPC input exceeds the 16 MiB limit");
  }
  return callWasmUtf8(module, dispatch, outputLength, state, json, {
    label: "WASM JSON-RPC",
    maxInputBytes: MAX_LSP_FRAME_BYTES,
    maxOutputBytes: MAX_LSP_DISPATCH_OUTPUT_BYTES,
    inputSizeError: "WASM JSON-RPC input exceeds the 16 MiB limit",
    outputSizeError: "WASM JSON-RPC output exceeds the 16 MiB limit",
  });
}
