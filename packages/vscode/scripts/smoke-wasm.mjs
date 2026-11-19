// Runs the packaged runtime the way the extension does: wasm/lus.wasm
// through the lus-wasm host, with the language server mounted from the
// packaged language-server directory. Pass the wasm directory and,
// optionally, the language server directory.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { loadLus, mountLanguageServer, MAX_LSP_FRAME_BYTES } from "lus-wasm";

if (process.env.LUS_DEVCONTAINER_QUALIFICATION === "1") {
  assert.equal(process.platform, "linux", "remote smoke must run on Linux");
  assert.ok(
    fs.existsSync("/.dockerenv"),
    "remote smoke must run inside the provisioned Dev Container",
  );
}

const wasmDirectory = path.resolve(process.argv[2] ?? "wasm");
const languageServerDirectory = path.resolve(
  process.argv[3] ?? path.join(wasmDirectory, "..", "language-server"),
);
const trace = (message) => {
  if (process.env.LUS_WASM_TRACE === "1") console.error(message);
};

const lus = await loadLus(path.join(wasmDirectory, "lus.wasm"));
await mountLanguageServer(lus, languageServerDirectory);

function notificationWithPayload(payload) {
  return `{"jsonrpc":"2.0","method":"$/limit","params":"${payload}"}`;
}

function asciiNotificationAt(byteLength) {
  const fixedBytes = Buffer.byteLength(notificationWithPayload(""));
  assert.ok(byteLength >= fixedBytes);
  const value = notificationWithPayload("x".repeat(byteLength - fixedBytes));
  assert.equal(Buffer.byteLength(value), byteLength);
  return value;
}

function parseFrames(output) {
  const bytes = Buffer.from(output, "utf8");
  const messages = [];
  let offset = 0;
  while (offset < bytes.length) {
    const headerEnd = bytes.indexOf("\r\n\r\n", offset);
    assert.notEqual(headerEnd, -1, "WASM returned a truncated LSP header");
    const header = bytes.subarray(offset, headerEnd).toString("latin1");
    const match = /^Content-Length: ([0-9]+)$/.exec(header);
    assert.ok(match, `WASM returned a noncanonical LSP header: ${header}`);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + Number(match[1]);
    assert.ok(bodyEnd <= bytes.length, "WASM returned a truncated LSP body");
    messages.push(JSON.parse(bytes.subarray(bodyStart, bodyEnd).toString("utf8")));
    offset = bodyEnd;
  }
  return messages;
}

const state = lus.create();
assert.ok(state, "WASM could not create a Lus state");
try {
  trace("load the language server");
  assert.equal(lus.loadLsp(state, lus.getLspSource()), "");

  const handle = (message) => lus.handleMessage(state, JSON.stringify(message));
  const notify = (method, params) => handle({ jsonrpc: "2.0", method, params });
  const rootOne = "vscode-remote://dev-container+fixture/workspaces/one";
  const rootTwo = "memfs://authority/workspaces/two";

  trace("reset the mirrored workspace");
  assert.equal(notify("lus/workspace/reset", { roots: [rootOne, rootTwo] }), "");
  assert.equal(
    notify("lus/workspace/upsert", {
      rootUri: rootOne,
      relativePath: "lib/alpha.lus",
      uri: `${rootOne}/lib/alpha.lus`,
      version: 1,
      text: "global alpha\nfunction alpha() return 1 end\n",
    }),
    "",
  );
  assert.equal(
    notify("lus/workspace/upsert", {
      rootUri: rootTwo,
      relativePath: "beta.lus",
      uri: `${rootTwo}/beta.lus`,
      version: 1,
      text: "global beta\nfunction beta() return 2 end\n",
    }),
    "",
  );

  trace("initialize");
  const initialize = parseFrames(
    handle({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        processId: null,
        rootUri: rootOne,
        workspaceFolders: [
          { uri: rootOne, name: "one" },
          { uri: rootTwo, name: "two" },
        ],
        capabilities: {},
      },
    }),
  );
  assert.equal(initialize.length, 1);
  assert.equal(initialize[0].result.serverInfo.name, "lus-language");

  trace("query closed workspace symbols");
  const symbols = parseFrames(
    handle({
      jsonrpc: "2.0",
      id: 2,
      method: "workspace/symbol",
      params: { query: "" },
    }),
  );
  assert.equal(symbols.length, 1);
  assert.ok(symbols[0].result.some((symbol) => symbol.name === "alpha"));
  assert.ok(symbols[0].result.some((symbol) => symbol.name === "beta"));

  trace("open a document with non-ASCII text and an error");
  const uri = `${rootOne}/main.lus`;
  const opened = parseFrames(
    notify("textDocument/didOpen", {
      textDocument: {
        uri,
        languageId: "lus",
        version: 1,
        text: 'local greeting = "héllo wörld"\nlocal x = = 1\n',
      },
    }),
  );
  const diagnostics = opened.find(
    (message) => message.method === "textDocument/publishDiagnostics",
  );
  assert.ok(diagnostics, "didOpen published no diagnostics");
  assert.ok(diagnostics.params.diagnostics.length > 0);

  trace("dispatch exact-limit notifications");
  const exactLimit = asciiNotificationAt(MAX_LSP_FRAME_BYTES);
  assert.equal(lus.handleMessage(state, exactLimit), "");
  assert.equal(notify("$/limit", "the state stays usable"), "");

  trace("reject an oversized body before dispatch");
  const oversized = parseFrames(
    lus.handleMessage(state, asciiNotificationAt(MAX_LSP_FRAME_BYTES + 1)),
  );
  assert.equal(oversized[0].error.code, -32700);
  const fixedBytes = Buffer.byteLength(notificationWithPayload(""));
  const multibyteOverflow = notificationWithPayload(
    "é".repeat(Math.floor((MAX_LSP_FRAME_BYTES - fixedBytes) / 2) + 1),
  );
  assert.ok(multibyteOverflow.length < MAX_LSP_FRAME_BYTES);
  assert.equal(parseFrames(lus.handleMessage(state, multibyteOverflow))[0].error.code, -32700);

  trace("answer malformed JSON with a parse error");
  const malformed = parseFrames(lus.handleMessage(state, "{"));
  assert.equal(malformed[0].error.code, -32700);

  trace("shut down");
  const shutdown = parseFrames(handle({ jsonrpc: "2.0", id: 3, method: "shutdown" }));
  assert.equal(shutdown[0].id, 3);
} finally {
  lus.destroy(state);
}

trace("execute playground input");
const executionState = lus.create();
try {
  assert.equal(lus.execute(executionState, `--${"x".repeat(2 * 1024 * 1024)}`), "");
  assert.equal(lus.execute(executionState, "2 + 2"), "4\n");
  assert.equal(lus.execute(executionState, '#"héllo"'), "5\n");
  const nulOutput = lus.execute(
    executionState,
    'local statement = true\nio.write("left" .. "\\0" .. "right")',
  );
  assert.equal(nulOutput, "left\0right");
  for (const source of [
    'local statement = true\nio.write(string.rep("w", 300 * 1024))',
    'local statement = true\nio.stderr:write(string.rep("e", 300 * 1024))',
  ]) {
    const output = lus.execute(executionState, source);
    assert.equal(Buffer.byteLength(output), 256 * 1024);
    assert.ok(output.endsWith("\n[Output truncated at 256 KiB.]\n"));
  }
  assert.notEqual(lus.execute(executionState, `local =${" ".repeat(1024)}`), "");
  assert.equal(lus.execute(executionState, "3 + 3"), "6\n");
} finally {
  lus.destroy(executionState);
}

trace("scope states with pledges");
lus.fs.writeFile("/outside.lus", "return 99\n");
const sealedState = lus.create();
const grantedState = lus.create();
try {
  const sealed = lus.execute(
    sealedState,
    'global pledge, loadfile, print, tostring\n' +
      'pledge("load", "seal")\n' +
      'local outside_ok, reason = catch loadfile("/outside.lus")\n' +
      'print("outside", outside_ok, tostring(reason))\n',
  );
  assert.match(sealed, /outside\s+false\s+.*permission "fs:read" denied/);
  const granted = lus.execute(
    grantedState,
    'global pledge, require, print, type, package\n' +
      "package.path = '/?.lus;/?/init.lus;' .. package.path\n" +
      'pledge("load", "fs:read", "seal")\n' +
      'local module_ok, value = catch require("lus-language.protocol")\n' +
      'print("module", module_ok, type(value))\n',
  );
  assert.match(granted, /module\s+true\s+table/);
} finally {
  lus.destroy(sealedState);
  lus.destroy(grantedState);
}

console.log("WASM extension smoke passed");
