import * as esbuild from "esbuild";
import { copyFile, cp, mkdir, rm, stat } from "node:fs/promises";

const watch = process.argv.includes("--watch");

await mkdir("licenses", { recursive: true });
// The license texts of the components compiled into lus.wasm, and of the
// language server lineage.
const licenses = ["BROTLI", "LUALS", "SQLITE", "TZDATA", "WASI-LIBC", "ZIG", "ZSTD"];
await Promise.all(
  licenses.map((name) =>
    copyFile(
      `../../packaging/licenses/LICENSE.${name}.txt`,
      `licenses/LICENSE.${name}.txt`,
    ),
  ),
);

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
