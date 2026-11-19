export function packagedWasmAsset(file: string): string {
  return file === "lus.node.wasm" ? "lus.wasm" : file;
}
