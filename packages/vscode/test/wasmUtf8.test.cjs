const assert = require("node:assert/strict");
const test = require("node:test");

const {
  MAX_LSP_DISPATCH_OUTPUT_BYTES,
  MAX_LSP_FRAME_BYTES,
} = require("../.test-out/lspFrames.js");
const {
  callWasmUtf8,
  dispatchJsonRpcUtf8,
} = require("../.test-out/wasmUtf8.js");

function mockModule(output = "{}") {
  const calls = [];
  const heap = new Uint8Array(512);
  const outputBytes =
    typeof output === "string" ? new TextEncoder().encode(output) : output;
  heap.set(outputBytes, 128);
  return {
    calls,
    module: {
      HEAPU8: heap,
      _malloc(size) {
        calls.push(["malloc", size]);
        return 64;
      },
      _free(pointer) {
        calls.push(["free", pointer]);
      },
      lengthBytesUTF8(value) {
        return Buffer.byteLength(value, "utf8");
      },
      stringToUTF8(value, pointer, capacity) {
        const length = Buffer.byteLength(value, "utf8");
        calls.push(["encode", pointer, capacity, length]);
        return length;
      },
    },
  };
}

test("uses a caller-freed heap buffer at the exact input limit", () => {
  const { calls, module } = mockModule();
  const exact = "x".repeat(MAX_LSP_FRAME_BYTES);
  let dispatchArgs;
  const output = dispatchJsonRpcUtf8(
    module,
    (...args) => {
      dispatchArgs = args;
      return 128;
    },
    () => 2,
    7,
    exact,
  );

  assert.equal(output, "{}");
  assert.deepEqual(dispatchArgs, [7, 64, MAX_LSP_FRAME_BYTES]);
  assert.deepEqual(calls[0], ["malloc", MAX_LSP_FRAME_BYTES + 1]);
  assert.deepEqual(calls.at(-1), ["free", 64]);
});

test("accepts a 2 MiB source without an arbitrary source cap", () => {
  const { calls, module } = mockModule();
  const source = "x".repeat(2 * 1024 * 1024);
  let callArgs;
  const output = callWasmUtf8(
    module,
    (...args) => {
      callArgs = args;
      return 128;
    },
    () => 2,
    7,
    source,
    { label: "WASM source" },
  );

  assert.equal(output, "{}");
  assert.deepEqual(callArgs, [7, 64, Buffer.byteLength(source)]);
  assert.deepEqual(calls[0], ["malloc", Buffer.byteLength(source) + 1]);
  assert.deepEqual(calls.at(-1), ["free", 64]);
});

test("decodes the exact output range across an embedded NUL", () => {
  const { module } = mockModule(new Uint8Array([65, 0, 66]));
  const output = callWasmUtf8(
    module,
    () => 128,
    () => 3,
    7,
    "x",
    { label: "WASM source" },
  );

  assert.equal(output, "A\0B");
  assert.equal(output.length, 3);
});

test("rejects malformed UTF-8 and output outside linear memory", () => {
  const malformed = mockModule(new Uint8Array([0xc0, 0x80]));
  assert.throws(
    () =>
      callWasmUtf8(malformed.module, () => 128, () => 2, 7, "x", {
        label: "WASM source",
      }),
    /not valid UTF-8/,
  );

  const outside = mockModule();
  assert.throws(
    () =>
      callWasmUtf8(outside.module, () => 510, () => 6, 7, "x", {
        label: "WASM source",
      }),
    /outside WASM linear memory/,
  );
});

test("rejects only unrepresentable sizes and genuine allocation failure", () => {
  const oversized = mockModule();
  oversized.module.lengthBytesUTF8 = () => 0xffff_ffff;
  assert.throws(
    () =>
      callWasmUtf8(oversized.module, () => 0, () => 0, 7, "x", {
        label: "WASM source",
      }),
    /not representable in wasm32/,
  );
  assert.deepEqual(oversized.calls, []);

  const exhausted = mockModule();
  exhausted.module._malloc = (size) => {
    exhausted.calls.push(["malloc", size]);
    return 0;
  };
  assert.throws(
    () =>
      callWasmUtf8(exhausted.module, () => 0, () => 0, 7, "x", {
        label: "WASM source",
      }),
    /allocation failed/,
  );
  assert.deepEqual(exhausted.calls, [["malloc", 2]]);
});

test("rejects byte overflow before allocating", () => {
  const oversized = mockModule();
  assert.throws(
    () =>
      dispatchJsonRpcUtf8(
        oversized.module,
        () => 0,
        () => 0,
        7,
        "x".repeat(MAX_LSP_FRAME_BYTES + 1),
      ),
    /input exceeds the 16 MiB limit/,
  );
  assert.deepEqual(oversized.calls, []);

  const multibyte = mockModule();
  const text = "é".repeat(MAX_LSP_FRAME_BYTES / 2 + 1);
  assert.ok(text.length < MAX_LSP_FRAME_BYTES);
  assert.ok(Buffer.byteLength(text, "utf8") > MAX_LSP_FRAME_BYTES);
  assert.throws(
    () =>
      dispatchJsonRpcUtf8(
        multibyte.module,
        () => 0,
        () => 0,
        7,
        text,
      ),
    /input exceeds the 16 MiB limit/,
  );
  assert.deepEqual(multibyte.calls, []);
});

test("frees input after dispatch and output failures", () => {
  const dispatchFailure = mockModule();
  assert.throws(
    () =>
      dispatchJsonRpcUtf8(
        dispatchFailure.module,
        () => {
          throw new Error("dispatch trap");
        },
        () => 0,
        7,
        "{}",
      ),
    /dispatch trap/,
  );
  assert.deepEqual(dispatchFailure.calls.at(-1), ["free", 64]);

  const outputFailure = mockModule();
  assert.throws(
    () =>
      dispatchJsonRpcUtf8(
        outputFailure.module,
        () => 128,
        () => MAX_LSP_DISPATCH_OUTPUT_BYTES + 1,
        7,
        "{}",
      ),
    /output exceeds the 16 MiB limit/,
  );
  assert.deepEqual(outputFailure.calls.at(-1), ["free", 64]);
});
