const assert = require("node:assert/strict");
const test = require("node:test");

const { packagedWasmAsset } = require("../.test-out/wasmAsset.js");

test("maps the Emscripten Node module name to the packaged shared module", () => {
  assert.equal(packagedWasmAsset("lus.node.wasm"), "lus.wasm");
});

test("preserves unrelated Emscripten assets", () => {
  assert.equal(packagedWasmAsset("support.data"), "support.data");
});
