import { Lus } from "./index.js";

export * from "./index.js";

/** Where `mise run wasm` puts lus.wasm inside this package. */
export const defaultWasmPath: string | null;
/** The language server sources in the repository. */
export const languageServerPath: string | null;

/** Loads lus.wasm from a file. */
export function loadLus(
  wasmPath?: string,
  options?: Parameters<typeof Lus.load>[1],
): Promise<Lus>;

/** Reads the files below `dir` with one of `extensions` for `MemFS.mount`. */
export function readHostDirectory(
  dir: string,
  extensions?: string[],
): Promise<Record<string, Uint8Array>>;

/** Copies the language server into /lus-language. */
export function mountLanguageServer(lus: Lus, dir?: string): Promise<void>;
