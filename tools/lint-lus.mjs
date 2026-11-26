#!/usr/bin/env node
// Checks that the Lus code of the repository is in the strict style
// (spec/design/style.md, section 14): `lus fmt --strict --check` over every
// tracked .lus file, `lus check --strict` over those outside `unchecked`,
// and `lus fmt --strict` over the ```lus code blocks of the manual, the
// spec, and the READMEs.
//
//   node tools/lint-lus.mjs [--write] [--lus PATH]
//
// --write formats the files and the code blocks in place instead of
// checking them. --lus names the interpreter, which defaults to
// runtime/zig-out/bin/lus.

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");

// Files that are test data rather than code, and generated files:
// fixtures whose expected output names lines and columns, sources that
// fail to parse on purpose, the grammar fixtures, whose tests read tokens
// by line, and the files the generators write.
export const skipped = [
  "tests/check/",
  "tests/doc/",
  "tests/debug/",
  "tests/conformance/fixtures/",
  "packages/textmate/test/fixtures/",
  // Written by tools/build-lsp.js and tools/build-facts.js.
  "packages/language-server/analysis/stdlib_data.lus",
  "packages/language-server/analysis/keywords.lus",
  "packages/language-server/version.lus",
];

// Files that are formatted but not checked. The scripts of the
// differential tests must print the same output under Lus and under the
// reference, so they keep the forms both understand. The benchmarks keep
// the forms whose speed they measure.
export const unchecked = ["tests/diff/", "tests/bench/"];

// The Markdown files whose ```lus blocks are code to format.
const docRoots = ["packages/site/src/manual/", "spec/", ".agents/", "examples/README.md", "README.md"];

export function isSkipped(file) {
  return skipped.some((prefix) => file.startsWith(prefix));
}

function tracked(pattern) {
  return execFileSync("git", ["ls-files", "-z", pattern], { cwd: root, encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
}

// The ```lus blocks of a Markdown text, with the offsets of their code.
// A block fenced as ```lus nocheck shows a fragment or an error, so it
// stays as written.
export function codeBlocks(text) {
  const blocks = [];
  const re = /^([ \t]*)```lus[ \t]*\r?\n([\s\S]*?)^\1```[ \t]*$/gm;
  for (const m of text.matchAll(re)) {
    if (m[1] !== "") continue;
    const start = m.index + m[0].indexOf("\n") + 1;
    blocks.push({ start, end: start + m[2].length, code: m[2] });
  }
  return blocks;
}

function format(lus, code) {
  const r = spawnSync(lus, ["fmt", "--strict", "-"], { input: code, encoding: "utf8" });
  return r.status === 0 ? r.stdout : null;
}

function main(argv) {
  const write = argv.includes("--write");
  const i = argv.indexOf("--lus");
  const lus = i >= 0 ? argv[i + 1] : path.join(root, "runtime/zig-out/bin/lus");
  if (!existsSync(lus)) {
    console.error(`lint-lus: build lus first (${path.relative(root, lus)} is missing)`);
    return 2;
  }
  let failed = 0;

  // A sparse checkout leaves some tracked files out of the working tree.
  const present = (f) => existsSync(path.join(root, f));
  // A file reached through a link to another checkout is checked but
  // never written, so --write changes only this working tree.
  const own = (f) => realpathSync(path.join(root, f)).startsWith(realpathSync(root) + path.sep);
  const files = tracked("*.lus").filter((f) => !isSkipped(f) && present(f));
  const fmt = spawnSync(lus, ["fmt", "--strict", write ? "--write" : "--check", ...files], { cwd: root, encoding: "utf8" });
  if (fmt.status !== 0) {
    process.stdout.write(fmt.stdout);
    process.stderr.write(fmt.stderr);
    failed++;
  }
  const checked = files.filter((f) => !unchecked.some((prefix) => f.startsWith(prefix)));
  const check = spawnSync(lus, ["check", "--strict", ...checked], { cwd: root, encoding: "utf8" });
  if (check.status !== 0) {
    process.stdout.write(check.stdout);
    process.stderr.write(check.stderr);
    failed++;
  }

  const docs = tracked("*.md").concat(tracked("*.mdx")).filter((f) => docRoots.some((r) => f === r || f.startsWith(r)) && present(f));
  for (const file of docs) {
    const text = readFileSync(path.join(root, file), "utf8");
    let out = "";
    let at = 0;
    let changed = false;
    for (const b of codeBlocks(text)) {
      const formatted = format(lus, b.code);
      out += text.slice(at, b.start);
      at = b.end;
      if (formatted === null || formatted === b.code) {
        out += b.code;
        continue;
      }
      changed = true;
      out += formatted;
      if (!write) {
        const line = text.slice(0, b.start).split("\n").length;
        console.log(`${file}:${line}: the code block is not in the strict style`);
      }
    }
    out += text.slice(at);
    if (changed && write && !own(file)) {
      console.error(`lint-lus: ${file} is outside this working tree, so it stays as it is`);
      failed++;
    } else if (changed && write) {
      try {
        writeFileSync(path.join(root, file), out);
      } catch (e) {
        console.error(`lint-lus: cannot write ${file} (${e.code})`);
        failed++;
      }
    }
    if (changed && !write) failed++;
  }
  return failed > 0 ? 1 : 0;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main(process.argv.slice(2)));
