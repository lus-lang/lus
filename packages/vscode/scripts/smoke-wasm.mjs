import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

if (process.env.LUS_DEVCONTAINER_QUALIFICATION === "1") {
  assert.equal(process.platform, "linux", "remote smoke must run on Linux");
  assert.ok(
    fs.existsSync("/.dockerenv"),
    "remote smoke must run inside the provisioned Dev Container",
  );
}

const wasmDirectory = path.resolve(process.argv[2] ?? "wasm");
const moduleUrl = pathToFileURL(path.join(wasmDirectory, "lus.mjs")).href;
const { default: createModule } = await import(moduleUrl);
assert.equal(typeof createModule, "function", "WASM module factory is missing");

const hostStdout = [];
const hostStderr = [];
const module = await createModule({
  print(value) {
    hostStdout.push(String(value));
  },
  printErr(value) {
    hostStderr.push(String(value));
  },
  locateFile(file) {
    const packaged = file === "lus.node.wasm" ? "lus.wasm" : file;
    return pathToFileURL(path.join(wasmDirectory, packaged)).href;
  },
});
assert.ok(module.FS, "Emscripten FS is not exported");
assert.ok(
  module.HEAPU8 instanceof Uint8Array,
  "Emscripten HEAPU8 is not exported",
);

const create = module.cwrap("lus_create", "number", []);
const executeBytes = module.cwrap("lus_execute_bytes", "number", [
  "number",
  "number",
  "number",
]);
const loadLspBytes = module.cwrap("lus_load_lsp_bytes", "number", [
  "number",
  "number",
  "number",
]);
const handleMessageBytes = module.cwrap("lus_handle_message_bytes", "number", [
  "number",
  "number",
  "number",
]);
const outputLength = module.cwrap("lus_output_length", "number", ["number"]);
const destroy = module.cwrap("lus_destroy", null, ["number"]);
const MAX_LSP_FRAME_BYTES = 16 * 1024 * 1024;
const MAX_LSP_OUTPUT_BYTES = MAX_LSP_FRAME_BYTES + 8 * 1024;
let inputAllocations = 0;
let inputFrees = 0;
const outputDecoder = new TextDecoder("utf-8", { fatal: true });
const trace = (message) => {
  if (process.env.LUS_WASM_TRACE === "1") console.error(message);
};

function callUtf8(
  state,
  input,
  call,
  {
    label,
    maxInputBytes = 0xffff_fffe,
    maxOutputBytes = 0xffff_ffff,
  },
) {
  const inputBytes = module.lengthBytesUTF8(input);
  if (
    !Number.isSafeInteger(inputBytes) ||
    inputBytes < 0 ||
    inputBytes > maxInputBytes ||
    inputBytes > 0xffff_fffe
  ) {
    throw new Error(`${label} input exceeds its byte limit`);
  }

  const inputPointer = module._malloc(inputBytes + 1);
  assert.ok(inputPointer > 0, `${label} input allocation failed`);
  inputAllocations += 1;
  try {
    assert.equal(
      module.stringToUTF8(input, inputPointer, inputBytes + 1),
      inputBytes,
      `${label} input encoding changed its byte length`,
    );
    const outputPointer = call(state, inputPointer, inputBytes);
    const outputBytes = outputLength(state);
    assert.ok(
      Number.isSafeInteger(outputBytes) &&
        outputBytes >= 0 &&
        outputBytes <= maxOutputBytes,
      `${label} output exceeded its byte limit`,
    );
    if (outputBytes === 0) return "";
    assert.ok(outputPointer > 0, `${label} output pointer is missing`);
    assert.ok(
      outputPointer <= module.HEAPU8.byteLength &&
        outputBytes <= module.HEAPU8.byteLength - outputPointer,
      `${label} output is outside WASM linear memory`,
    );
    return outputDecoder.decode(
      module.HEAPU8.subarray(outputPointer, outputPointer + outputBytes),
    );
  } finally {
    module._free(inputPointer);
    inputFrees += 1;
  }
}

function handleMessage(state, json) {
  return callUtf8(state, json, handleMessageBytes, {
    label: "WASM JSON-RPC",
    maxInputBytes: MAX_LSP_FRAME_BYTES,
    maxOutputBytes: MAX_LSP_OUTPUT_BYTES,
  });
}

function execute(state, source) {
  return callUtf8(state, source, executeBytes, { label: "WASM source" });
}

function loadLsp(state, source) {
  return callUtf8(state, source, loadLspBytes, {
    label: "WASM language server",
  });
}

function notificationWithPayload(payload) {
  return `{"jsonrpc":"2.0","method":"$/limit","params":"${payload}"}`;
}

function asciiNotificationAt(byteLength) {
  const empty = notificationWithPayload("");
  const fixedBytes = module.lengthBytesUTF8(empty);
  assert.ok(byteLength >= fixedBytes);
  const value = notificationWithPayload("x".repeat(byteLength - fixedBytes));
  assert.equal(module.lengthBytesUTF8(value), byteLength);
  return value;
}

function parseFrames(output) {
  const messages = [];
  let offset = 0;
  while (offset < output.length) {
    const headerEnd = output.indexOf("\r\n\r\n", offset);
    assert.notEqual(headerEnd, -1, "WASM returned a truncated LSP header");
    const header = output.slice(offset, headerEnd);
    const match = /^Content-Length: ([0-9]+)$/.exec(header);
    assert.ok(match, `WASM returned a noncanonical LSP header: ${header}`);
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    let bodyEnd = bodyStart;
    let bodyLength = 0;
    while (bodyLength < length && bodyEnd < output.length) {
      const codePoint = output.codePointAt(bodyEnd);
      assert.notEqual(codePoint, undefined);
      const character = String.fromCodePoint(codePoint);
      bodyLength += Buffer.byteLength(character, "utf8");
      bodyEnd += character.length;
    }
    assert.equal(bodyLength, length, "WASM returned an invalid UTF-8 LSP body");
    const body = output.slice(bodyStart, bodyEnd);
    messages.push(JSON.parse(body));
    offset = bodyEnd;
  }
  return messages;
}

const state = create();
assert.ok(state, "WASM could not create a Lus state");
try {
  trace("load embedded LSP");
  const source = module.FS.readFile("/lus-language/wasm.lus", {
    encoding: "utf8",
  });
  const largeLspBytes = 2 * 1024 * 1024;
  const paddedSource = `${source}\n--${"x".repeat(
    largeLspBytes - module.lengthBytesUTF8(source) - 3,
  )}`;
  assert.equal(module.lengthBytesUTF8(paddedSource), largeLspBytes);
  assert.equal(
    loadLsp(state, paddedSource),
    "",
    "2 MiB embedded LSP module loading failed",
  );

  const notify = (method, params) =>
    handleMessage(state, JSON.stringify({ jsonrpc: "2.0", method, params }));
  const rootOne = "vscode-remote://dev-container+fixture/workspaces/one";
  const rootTwo = "memfs://authority/workspaces/two";
  trace("reset mirrored workspace");
  assert.equal(
    notify("lus/workspace/reset", { roots: [rootOne, rootTwo] }),
    "",
  );
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

  trace("initialize LSP");
  const initialize = parseFrames(
    handleMessage(
      state,
      JSON.stringify({
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
    ),
  );
  assert.equal(initialize.length, 1);
  assert.equal(initialize[0].result.serverInfo.version, "1.7.0");

  trace("query closed workspace symbols");
  const symbols = parseFrames(
    handleMessage(
      state,
      JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        method: "workspace/symbol",
        params: { query: "" },
      }),
    ),
  );
  assert.equal(symbols.length, 1);
  assert.ok(symbols[0].result.some((symbol) => symbol.name === "alpha"));
  assert.ok(symbols[0].result.some((symbol) => symbol.name === "beta"));

  trace("dispatch exact-limit heap-backed notifications");
  const exactLimit = asciiNotificationAt(MAX_LSP_FRAME_BYTES);
  assert.equal(handleMessage(state, exactLimit), "");
  assert.equal(handleMessage(state, exactLimit), "");
  assert.equal(
    notify("$/limit", "state remains reusable after exact-limit dispatch"),
    "",
  );

  trace("reject oversized UTF-8 before allocation");
  const allocationsBeforeOverflow = inputAllocations;
  assert.throws(
    () => handleMessage(state, asciiNotificationAt(MAX_LSP_FRAME_BYTES + 1)),
    /input exceeds/,
  );
  assert.equal(inputAllocations, allocationsBeforeOverflow);

  const fixedBytes = module.lengthBytesUTF8(notificationWithPayload(""));
  const multibyteOverflow = notificationWithPayload(
    "é".repeat(Math.floor((MAX_LSP_FRAME_BYTES - fixedBytes) / 2) + 1),
  );
  assert.ok(multibyteOverflow.length < MAX_LSP_FRAME_BYTES);
  assert.ok(
    module.lengthBytesUTF8(multibyteOverflow) > MAX_LSP_FRAME_BYTES,
  );
  assert.throws(
    () => handleMessage(state, multibyteOverflow),
    /input exceeds/,
  );
  assert.equal(inputAllocations, allocationsBeforeOverflow);
} finally {
  trace("destroy LSP state");
  destroy(state);
}

trace("execute 2 MiB source and parse error through heap buffers");
const executionState = create();
assert.ok(executionState, "WASM could not create an execution state");
try {
  const largeSource = `--${"x".repeat(2 * 1024 * 1024)}`;
  assert.equal(execute(executionState, largeSource), "");
  assert.equal(execute(executionState, "2 + 2"), "4\n");

  trace("preserve embedded NUL output bytes");
  const nulOutput = execute(
    executionState,
    'local ignored = 0\nio.write("left" .. string.char(0) .. "right")',
  );
  assert.equal(nulOutput, "left\0right");
  assert.equal(nulOutput.length, 10);

  trace("capture and cap every standard output surface");
  const stdoutCount = hostStdout.length;
  const stderrCount = hostStderr.length;
  for (const source of [
    'local ignored = 0\nio.write(string.rep("w", 300 * 1024))',
    'local ignored = 0\nio.stderr:write(string.rep("e", 300 * 1024))',
    'local ignored = 0\nio.stdout:write(string.rep("o", 300 * 1024))',
  ]) {
    const output = execute(executionState, source);
    assert.equal(new TextEncoder().encode(output).byteLength, 256 * 1024);
    assert.ok(output.endsWith("\n[Output truncated at 256 KiB.]\n"));
  }
  assert.equal(hostStdout.length, stdoutCount);
  assert.equal(hostStderr.length, stderrCount);

  trace("reject the raw debug console through bounded output");
  assert.match(
    execute(executionState, "debug.debug()"),
    /debug\.debug is unavailable in WebAssembly/,
  );
  assert.equal(hostStdout.length, stdoutCount);
  assert.equal(hostStderr.length, stderrCount);

  trace("reject every filesystem route to host console devices");
  try {
    module.FS.unlink("/console-output-alias");
  } catch {}
  try {
    module.FS.unlink("/console-output-chain");
  } catch {}
  module.FS.writeFile("/console-copy-source", "CONSOLE-BYPASS\n");
  module.FS.symlink("/dev/stdout", "/console-output-alias");
  module.FS.symlink("/console-output-alias", "/console-output-chain");
  const consoleDenial = execute(
    executionState,
    'global pledge, io, fs, debug, print, tostring, type\n' +
      'pledge("fs:read=/dev/stdout", "fs:write=/dev/stdout", ' +
      '"fs:write=/dev/stderr", "fs:read=/dev/tty", ' +
      '"fs:write=/dev/tty", "fs:write=/dev/tty1", ' +
      '"fs:write=/console-output-alias", "fs:write=/console-output-chain", ' +
      '"fs:write=/renamed-console-device", ' +
      '"fs:write=/script-moved-console", ' +
      '"fs:read=/console-copy-source")\n' +
      'local direct_ok, direct_reason = catch io.open("/dev/stdout", "w")\n' +
      'local error_ok, error_reason = catch io.output("/dev/stderr")\n' +
      'local tty_ok, tty_reason = catch io.open("/dev/tty", "a")\n' +
      'local tty1_ok, tty1_reason = catch io.open("/dev/tty1", "w")\n' +
      'local alias_ok, alias_reason = catch io.open("/console-output-alias", "w")\n' +
      'local chain_ok, chain_reason = catch io.open("/console-output-chain", "w")\n' +
      'local copy_ok, copy_reason = catch fs.copy("/console-copy-source", "/dev/stdout")\n' +
      'local alias_copy_ok, alias_copy_reason = catch fs.copy("/console-copy-source", "/console-output-alias")\n' +
      'local move_ok, move_reason = catch fs.move("/dev/tty", "/script-moved-console")\n' +
      'local read_ok, read_file = catch io.open("/dev/stdout", "r")\n' +
      'local read_write_ok, read_write_reason = false, "read open failed"\n' +
      'if read_ok then\n' +
      '    local call_ok, value, reason = catch read_file:write("READ-MODE-BYPASS\\n")\n' +
      '    read_write_ok = call_ok and value ~= nil\n' +
      '    read_write_reason = reason\n' +
      '    read_file:close()\n' +
      'end\n' +
      'local _, raw_open = debug.getupvalue(io.open, 1)\n' +
      'local raw_ok, raw_reason = false, "no recoverable raw io.open"\n' +
      'if type(raw_open) == "function" then\n' +
      '    raw_ok, raw_reason = catch raw_open("/dev/stdout", "w")\n' +
      'end\n' +
      'print("direct", direct_ok, tostring(direct_reason))\n' +
      'print("stderr", error_ok, tostring(error_reason))\n' +
      'print("tty", tty_ok, tostring(tty_reason))\n' +
      'print("tty1", tty1_ok, tostring(tty1_reason))\n' +
      'print("alias", alias_ok, tostring(alias_reason))\n' +
      'print("chain", chain_ok, tostring(chain_reason))\n' +
      'print("copy", copy_ok, tostring(copy_reason))\n' +
      'print("alias-copy", alias_copy_ok, tostring(alias_copy_reason))\n' +
      'print("move", move_ok, tostring(move_reason))\n' +
      'print("read-mode-write", read_write_ok, tostring(read_write_reason))\n' +
      'print("raw-upvalue", raw_ok, tostring(raw_reason))',
  );
  assert.match(consoleDenial, /direct\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /stderr\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /tty\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /tty1\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /alias\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /chain\s+false\s+.*host console devices/);
  assert.match(consoleDenial, /copy\s+false\s+/);
  assert.match(consoleDenial, /alias-copy\s+false\s+/);
  assert.match(consoleDenial, /move\s+false\s+/);
  assert.match(consoleDenial, /read-mode-write\s+false\s+/);
  assert.match(consoleDenial, /raw-upvalue\s+false\s+/);
  assert.equal(hostStdout.length, stdoutCount);
  assert.equal(hostStderr.length, stderrCount);

  trace("reject a console device after its MEMFS node is renamed");
  let consoleDeviceRenamed = false;
  try {
    module.FS.rename("/dev/tty", "/renamed-console-device");
    consoleDeviceRenamed = true;
    const renamedDenial = execute(
      executionState,
      'global io, fs, print, tostring\n' +
        'local open_ok, open_reason = catch io.open("/renamed-console-device", "w")\n' +
        'local copy_ok, copy_reason = catch fs.copy("/console-copy-source", "/renamed-console-device")\n' +
        'print("renamed-open", open_ok, tostring(open_reason))\n' +
        'print("renamed-copy", copy_ok, tostring(copy_reason))',
    );
    assert.match(
      renamedDenial,
      /renamed-open\s+false\s+.*host console devices/,
    );
    assert.match(renamedDenial, /renamed-copy\s+false\s+/);
    assert.equal(hostStdout.length, stdoutCount);
    assert.equal(hostStderr.length, stderrCount);
  } finally {
    if (consoleDeviceRenamed)
      module.FS.rename("/renamed-console-device", "/dev/tty");
  }
  assert.equal(execute(executionState, "7 + 7"), "14\n");

  const largeParseError = `local =${" ".repeat(2 * 1024 * 1024)}`;
  assert.notEqual(execute(executionState, largeParseError), "");
  assert.equal(execute(executionState, "3 + 3"), "6\n");
} finally {
  destroy(executionState);
}

trace("create scoped pledge state");
module.FS.writeFile("/outside.lus", "return 99\n");
const pledgeState = create();
assert.ok(pledgeState, "WASM could not create the pledge test state");
try {
  const output = execute(
    pledgeState,
    'global pledge, require, loadfile, print, type, tostring\n' +
      'pledge("load", "fs:read=/lus-language/*", "seal")\n' +
      'local module_ok, value = catch require("lus-language.protocol")\n' +
      'print("module", module_ok, type(value))\n' +
      'local outside_ok, reason = catch loadfile("/outside.lus")\n' +
      'print("outside", outside_ok, tostring(reason))\n',
  );
  assert.match(output, /module\s+true\s+table/);
  assert.match(output, /outside\s+false\s+.*permission "fs:read" denied/);
} finally {
  destroy(pledgeState);
}

assert.equal(inputFrees, inputAllocations, "every WASM input buffer was freed");

console.log("WASM extension smoke passed");
