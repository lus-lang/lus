#!/usr/bin/env node
// Repository-wide prose and naming checks. Run: node tools/lint-repo.js
//
// Rules:
// - No em dashes or en dashes anywhere in tracked text files.
// - The name of one particular other Lua dialect is never mentioned. The
//   word is assembled at runtime so this file does not contain it.

const {execFileSync} = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const FORBIDDEN_NAME = ["l", "u", "a", "u"].join("");

// The frozen legacy runtime, lockfiles, and binary or generated vendor
// content are excluded. Everything else is held to the rules.
const EXCLUDED = [
  /^legacy\//,
  /^packaging\/licenses\//,
  /(^|\/)pnpm-lock\.yaml$/,
  /\.(png|jpg|jpeg|gif|ico|woff2?|ttf|otf|wasm|vsix|pdf)$/i,
];

const files = execFileSync("git", ["ls-files", "-z"], {cwd: ROOT, encoding: "utf8"})
  .split("\0")
  .filter((file) => file && !EXCLUDED.some((pattern) => pattern.test(file)));

const nameRule = new RegExp(`(?<![A-Za-z_])${FORBIDDEN_NAME}(?![A-Za-z_])`, "i");
const failures = [];

for (const file of files) {
  const full = path.join(ROOT, file);
  let text;
  try {
    if (!fs.statSync(full).isFile()) continue;
    text = fs.readFileSync(full, "utf8");
  } catch {
    continue;
  }
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    const where = `${file}:${index + 1}`;
    if (/[\u2013\u2014]/.test(line)) failures.push(`${where}: em or en dash`);
    if (nameRule.test(line)) failures.push(`${where}: forbidden dialect name`);
  });
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  console.error(`\n${failures.length} problem(s) found`);
  process.exit(1);
}
console.log(`Checked ${files.length} files`);
