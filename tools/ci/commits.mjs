#!/usr/bin/env node
// Checks commit messages against the format of CONTRIBUTING.md.
//
//   node tools/ci/commits.mjs message FILE      the commit-msg hook
//   node tools/ci/commits.mjs range BASE HEAD   every commit of a pull request
//
// The first line is `type(area): subject`. The type is one of TYPES, and
// the area is a label of tools/ci/areas.json. The subject is imperative,
// starts with a lowercase letter, has no final period, and the whole line
// holds at most 72 characters. A body, when there is one, follows a blank
// line and holds no em or en dash, no semicolon outside code, and never
// names the dialect that tools/lint-repo.js keeps out of the repository.
// Merge commits are left out of a range.

import {execFileSync} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const TYPES = ["fix", "perf", "feat", "refactor", "test", "docs", "ci", "build", "chore"];
export const AREAS = Object.keys(JSON.parse(fs.readFileSync(path.join(ROOT, "tools/ci/areas.json"), "utf8")).labels).filter((k) => k !== "about");
const FORBIDDEN_NAME = ["l", "u", "a", "u"].join("");
const NAME_RULE = new RegExp(`(?<![A-Za-z_])${FORBIDDEN_NAME}(?![A-Za-z_])`, "i");
const TRAILER = /^[A-Za-z][A-Za-z-]*: \S/;

// Returns the problems of one message, an empty list when it is sound.
// Lines that git strips, which start with #, are left out first.
export function checkMessage(text) {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const scissors = lines.findIndex((l) => /^# -+ >8 -+$/.test(l));
  const kept = (scissors >= 0 ? lines.slice(0, scissors) : lines).filter((l) => !l.startsWith("#"));
  while (kept.length && kept[kept.length - 1].trim() === "") kept.pop();
  const problems = [];
  const first = kept[0] ?? "";
  // git writes these itself, and they leave the branch before it merges.
  if (/^(fixup|squash|amend)! /.test(first)) return problems;

  const m = /^([a-z]+)\(([a-z0-9-]+)\): (.*)$/.exec(first);
  if (!m) {
    problems.push(`write the first line as type(area): subject, in place of "${first}"`);
  } else {
    const [, type, area, subject] = m;
    if (!TYPES.includes(type)) problems.push(`use one of ${TYPES.join(", ")} as the type, in place of "${type}"`);
    if (!AREAS.includes(area)) problems.push(`use one of ${AREAS.join(", ")} as the area, in place of "${area}"`);
    if (subject.trim() === "") problems.push("write a subject after the colon");
    else if (!/^[a-z0-9`]/.test(subject)) problems.push("start the subject with a lowercase letter");
    if (/\.$/.test(subject)) problems.push("end the subject without a period");
    if (/\s$/.test(subject)) problems.push("end the subject without a space");
  }
  if ([...first].length > 72) problems.push(`shorten the first line to at most 72 characters, from ${[...first].length}`);
  if (kept.length > 1 && kept[1].trim() !== "") problems.push("leave a blank line between the first line and the body");

  let fence = false;
  for (const [i, line] of kept.entries()) {
    if (i === 0) continue;
    if (/^\s*```/.test(line)) {
      fence = !fence;
      continue;
    }
    const where = `line ${i + 1}`;
    if (/[\u2013\u2014]/.test(line)) problems.push(`rewrite ${where} without the em or en dash`);
    if (NAME_RULE.test(line)) problems.push(`leave out of ${where} the name of the dialect that the repository never names`);
    // Code blocks, indented code, inline code, and trailers may hold
    // semicolons.
    if (fence || /^( {4}|\t)/.test(line) || TRAILER.test(line)) continue;
    if (line.replace(/`[^`]*`/g, "").includes(";")) problems.push(`split ${where} into sentences at its semicolon`);
  }
  return problems;
}

function git(args) {
  return execFileSync("git", args, {cwd: ROOT, encoding: "utf8"});
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (command === "message" && rest.length === 1) {
    const problems = checkMessage(fs.readFileSync(rest[0], "utf8"));
    for (const p of problems) console.error(`commit-msg: ${p}`);
    if (problems.length) console.error("commit-msg: read the format in CONTRIBUTING.md. Your message is saved in .git/COMMIT_EDITMSG, so run git commit -e -F .git/COMMIT_EDITMSG to edit it.");
    process.exit(problems.length ? 1 : 0);
  }
  if (command === "range" && rest.length === 2) {
    const [base, head] = rest;
    const shas = git(["rev-list", "--no-merges", "--reverse", `${base}..${head}`]).split("\n").filter(Boolean);
    let failed = 0;
    for (const sha of shas) {
      const problems = checkMessage(git(["log", "-1", "--format=%B", sha]));
      if (problems.length) failed++;
      for (const p of problems) console.log(`${sha.slice(0, 10)}: ${p}`);
    }
    console.log(`${shas.length} commits checked, ${failed} with problems`);
    process.exit(failed ? 1 : 0);
  }
  console.error("usage: commits.mjs message FILE | commits.mjs range BASE HEAD");
  process.exit(2);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
