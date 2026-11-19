const assert = require("node:assert/strict");
const test = require("node:test");

const {
  MAX_LSP_FRAME_BYTES,
  parseLspFrames,
  serializeJsonRpcMessage,
} = require("../.test-out/lspFrames.js");

function frame(message, extraHeaders = []) {
  const body = JSON.stringify(message);
  const length = Buffer.byteLength(body, "utf8");
  return [
    `Content-Length: ${length}`,
    ...extraHeaders,
    "",
    body,
  ].join("\r\n");
}

test("parses UTF-8 and consecutive frames exactly", () => {
  const first = { jsonrpc: "2.0", id: 1, result: "héllo" };
  const second = { jsonrpc: "2.0", method: "ready", params: {} };
  assert.deepEqual(parseLspFrames(frame(first) + frame(second)), [first, second]);
});

test("accepts the explicit UTF-8 content type", () => {
  const message = { jsonrpc: "2.0", id: 1, result: null };
  assert.deepEqual(
    parseLspFrames(
      frame(message, ["Content-Type: application/vscode-jsonrpc; charset=utf-8"]),
    ),
    [message],
  );
});

test("rejects duplicate headers", () => {
  assert.throws(
    () =>
      parseLspFrames(
        "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}",
      ),
    /Duplicate JSON-RPC header/,
  );
  assert.throws(
    () =>
      parseLspFrames(
        "Content-Length: 2\r\nX-Test: a\r\nx-test: b\r\n\r\n{}",
      ),
    /Duplicate JSON-RPC header/,
  );
});

test("rejects malformed headers and trailing data", () => {
  assert.throws(
    () => parseLspFrames("Content-Length: 2\n\n{}"),
    /Invalid or oversized JSON-RPC header/,
  );
  assert.throws(
    () => parseLspFrames(frame({ jsonrpc: "2.0" }) + "trailing"),
    /Invalid or oversized JSON-RPC header/,
  );
});

test("rejects oversized and truncated frames", () => {
  assert.throws(
    () => parseLspFrames(`Content-Length: ${MAX_LSP_FRAME_BYTES + 1}\r\n\r\n`),
    /16 MiB limit/,
  );
  assert.throws(
    () => parseLspFrames("Content-Length: 20\r\n\r\n{}"),
    /Truncated JSON-RPC frame/,
  );
});

test("rejects invalid UTF-8, JSON, and non-object bodies", () => {
  const header = Buffer.from("Content-Length: 2\r\n\r\n", "ascii");
  assert.throws(
    () => parseLspFrames(Buffer.concat([header, Buffer.from([0xc3, 0x28])])),
    /not valid UTF-8/,
  );
  assert.throws(
    () => parseLspFrames("Content-Length: 1\r\n\r\n{"),
    /not valid JSON/,
  );
  assert.throws(
    () => parseLspFrames("Content-Length: 2\r\n\r\n[]"),
    /must contain an object/,
  );
});

test("bounds outbound JSON-RPC messages by UTF-8 bytes", () => {
  assert.equal(
    serializeJsonRpcMessage({ jsonrpc: "2.0", method: "ready" }),
    '{"jsonrpc":"2.0","method":"ready"}',
  );
  assert.throws(
    () =>
      serializeJsonRpcMessage({
        jsonrpc: "2.0",
        method: "large",
        params: "x".repeat(MAX_LSP_FRAME_BYTES),
      }),
    /16 MiB limit/,
  );
});
