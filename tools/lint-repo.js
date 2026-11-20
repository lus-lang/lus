#!/usr/bin/env node
// Repository-wide prose and naming checks. Run: node tools/lint-repo.js
//
// Rules:
// - No em dashes or en dashes anywhere in tracked text files.
// - The name of one particular other Lua dialect is never mentioned. The
//   word is assembled at runtime so this file does not contain it. The
//   cross-language benchmark suite, which runs that dialect as one of its
//   runtimes, and the site files that publish its results may name it.

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

// Paths where the dialect name rule does not apply. The dash rule still
// applies to them.
const NAME_ALLOWED = [
  /^tests\/bench\/compare\//,
  /^packages\/site\/src\/data\/benchmarks\.json$/,
  /^packages\/site\/src\/components\/Benchmarks\.astro$/,
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
  const checkName = !NAME_ALLOWED.some((pattern) => pattern.test(file));
  lines.forEach((line, index) => {
    const where = `${file}:${index + 1}`;
    if (/[\u2013\u2014]/.test(line)) failures.push(`${where}: em or en dash`);
    if (checkName && nameRule.test(line)) failures.push(`${where}: forbidden dialect name`);
  });
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  console.error(`\n${failures.length} problem(s) found`);
  process.exit(1);
}
console.log(`Checked ${files.length} files`);
