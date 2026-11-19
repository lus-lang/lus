// Node helpers for the lus.wasm host: loading the module from disk and
// copying host directories, such as the language server, into the
// in-memory file system.

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Lus } from "./index.js";

export * from "./index.js";

// Bundlers that emit CommonJS leave `import.meta.url` undefined. Hosts
// bundled that way pass explicit paths, so the defaults fall back to null.
function besideThisPackage(relative) {
  try {
    return fileURLToPath(new URL(relative, import.meta.url));
  } catch {
    return null;
  }
}

/** Where `mise run wasm` puts the module inside this package. */
export const defaultWasmPath = besideThisPackage("../dist/lus.wasm");

/** The language server sources in the repository. */
export const languageServerPath = besideThisPackage("../../language-server");

/**
 * Loads lus.wasm from a file.
 * @param {string} [wasmPath]
 * @param {ConstructorParameters<typeof Lus>[1]} [options]
 */
export async function loadLus(wasmPath = defaultWasmPath, options = {}) {
  return Lus.load(await readFile(wasmPath), options);
}

/**
 * Reads every file below `dir` whose name ends in one of `extensions`
 * into a `{ relativePath: bytes }` object for `MemFS.mount`.
 */
export async function readHostDirectory(dir, extensions = [".lus"]) {
  const files = {};
  async function walk(sub) {
    for (const entry of await readdir(path.join(dir, sub), { withFileTypes: true })) {
      const rel = sub ? `${sub}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules" && !entry.name.startsWith(".")) await walk(rel);
      } else if (extensions.some((ext) => entry.name.endsWith(ext))) {
        files[rel] = await readFile(path.join(dir, rel));
      }
    }
  }
  await walk("");
  return files;
}

/** Copies the language server into /lus-language, where `loadLsp` expects it. */
export async function mountLanguageServer(lus, dir = languageServerPath) {
  lus.fs.mount(await readHostDirectory(dir), "/lus-language");
}
