// Runs one Lus file through lus.wasm, for the differential runner.
//
// Usage: node wasm.mjs MODE FILE [WASM]
//
// MODE is the LUS_JIT setting of the WebAssembly build: off, on, or eager.
// The script writes what the program wrote, byte for byte, then the error
// message to standard error with the prefix of the lus command, and exits
// with the status the command would have.

import { readFileSync } from "node:fs";
import { loadLus } from "../../packages/wasm/src/node.js";

const [mode, file, wasm] = process.argv.slice(2);
const lus = await loadLus(wasm, { env: { LUS_JIT: mode } });
const res = lus.run(readFileSync(file, "utf8"), { chunkname: "@" + file });
for (let i = 0; i < lus.capture.chunks.length; i++) {
    const out = lus.capture.streams[i] === "stdout" ? process.stdout : process.stderr;
    out.write(lus.capture.chunks[i]);
}
if (res.error) process.stderr.write("lus: " + res.error + "\n");
process.exitCode = res.exitCode;
