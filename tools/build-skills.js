#!/usr/bin/env node
// Copies spec/design/style.md into the lus-writing skill, so the skill that
// ships to other repositories carries the guide without a second hand-edited
// copy. Run: node tools/build-skills.js [--check]
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const SOURCE = path.join(ROOT, "spec", "design", "style.md");
const TARGET = path.join(ROOT, ".agents", "skills", "lus-writing", "references", "style.md");
const HEADER = "<!-- Generated from spec/design/style.md by tools/build-skills.js. Edit that file. -->\n\n";

const expected = HEADER + fs.readFileSync(SOURCE, "utf8");
if (process.argv.includes("--check")) {
  // An agent worktree leaves the copy out of its working tree
  // (tools/agent-worktree.sh), so the check then reads it from the index.
  let actual = "";
  if (fs.existsSync(TARGET)) {
    actual = fs.readFileSync(TARGET, "utf8");
  } else {
    try {
      actual = require("child_process").execFileSync("git", ["show", `:${path.relative(ROOT, TARGET)}`], {cwd: ROOT, encoding: "utf8"});
    } catch {}
  }
  if (actual !== expected) {
    console.error(`${path.relative(ROOT, TARGET)} is stale. Run node tools/build-skills.js.`);
    process.exit(1);
  }
} else {
  fs.writeFileSync(TARGET, expected);
}
