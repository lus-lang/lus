import * as esbuild from "esbuild";
import { copyFile, cp, mkdir, rm, stat } from "node:fs/promises";

const watch = process.argv.includes("--watch");

await mkdir("licenses", { recursive: true });
await Promise.all([
  copyFile(
    "../../packaging/licenses/LICENSE.EMSCRIPTEN.txt",
    "licenses/LICENSE.EMSCRIPTEN.txt",
  ),
  copyFile("../../packaging/licenses/LICENSE.LUALS.txt", "licenses/LICENSE.LUALS.txt"),
]);

// The extension runs the language server from its Lus sources, which the
// package carries in language-server/. The tests stay in the repository.
await rm("language-server", { recursive: true, force: true });
await cp("../language-server", "language-server", {
  recursive: true,
  filter: (source) =>
    !/[\\/]language-server[\\/]tests(?:[\\/]|$)/.test(source),
});

// `mise run wasm` builds lus.wasm into packages/wasm/dist. A build without
// it still bundles the extension, and packaging then reports the missing
// module.
const wasmSource = "../wasm/dist/lus.wasm";
if (await stat(wasmSource).catch(() => null)) {
  await mkdir("wasm", { recursive: true });
  await copyFile(wasmSource, "wasm/lus.wasm");
} else {
  console.warn(
    "packages/wasm/dist/lus.wasm is missing. Run `mise run wasm` before packaging.",
  );
}

const config = {
  entryPoints: ["src/extension.ts"],
  bundle: true,
  outfile: "out/extension.js",
  external: ["vscode"],
  format: "cjs",
  platform: "node",
  target: "node20",
  sourcemap: watch,
  minify: !watch,
  legalComments: "none",
  // lus-wasm resolves its default paths from import.meta.url, which a
  // CommonJS bundle leaves empty. The extension passes explicit paths.
  logOverride: { "empty-import-meta": "silent" },
};

if (watch) {
  const ctx = await esbuild.context(config);
  await ctx.watch();
  console.log("Watching for changes...");
} else {
  await esbuild.build(config);
  console.log("Build complete.");
}
