import { execFileSync } from "node:child_process";

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
  "wasm/lus.mjs",
  "wasm/lus.wasm",
];

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
