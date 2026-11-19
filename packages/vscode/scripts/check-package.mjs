import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import path from "node:path";

// The language server ships as its Lus sources, without its tests.
function languageServerFiles(dir, prefix = "language-server") {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) {
      files.push(...languageServerFiles(path.join(dir, entry.name), rel));
    } else if (entry.name.endsWith(".lus")) {
      files.push(rel);
    }
  }
  return files;
}

const expected = [
  "LICENSE",
  "README.md",
  "THIRD_PARTY_NOTICES.md",
  "icon.png",
  "language-configuration.json",
  "licenses/LICENSE.EMSCRIPTEN.txt",
  "licenses/LICENSE.LUALS.txt",
  "out/extension.js",
  "package.json",
  "syntaxes/lus.tmLanguage.json",
  "wasm/lus.wasm",
  ...languageServerFiles("language-server"),
].sort();

if (!expected.includes("language-server/wasm.lus")) {
  throw new Error("The staged language server is missing wasm.lus. Run pnpm build first.");
}

const output = execFileSync(
  process.platform === "win32" ? "pnpm.cmd" : "pnpm",
  ["exec", "vsce", "ls", "--no-dependencies"],
  { encoding: "utf8" },
);
const actual = output
  .split(/\r?\n/)
  .map((entry) => entry.trim())
  .filter(Boolean)
  .sort();

if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(
    `VSIX contents differ from the release allowlist. Found: ${actual.join(", ")}`,
  );
}
