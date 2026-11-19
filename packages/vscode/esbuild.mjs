import * as esbuild from "esbuild";
import { copyFile, mkdir } from "node:fs/promises";

const watch = process.argv.includes("--watch");

await mkdir("licenses", { recursive: true });
await Promise.all([
  copyFile(
    "../../packaging/licenses/LICENSE.EMSCRIPTEN.txt",
    "licenses/LICENSE.EMSCRIPTEN.txt",
  ),
  copyFile("../../packaging/licenses/LICENSE.LUALS.txt", "licenses/LICENSE.LUALS.txt"),
]);

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
};

if (watch) {
  const ctx = await esbuild.context(config);
  await ctx.watch();
  console.log("Watching for changes...");
} else {
  await esbuild.build(config);
  console.log("Build complete.");
}
