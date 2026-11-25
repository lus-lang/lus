// Tests of the commit message format. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import {AREAS, checkMessage} from "./commits.mjs";

const ok = (text) => assert.deepEqual(checkMessage(text), [], text);
const bad = (text, pattern) => {
  const problems = checkMessage(text);
  assert.ok(problems.some((p) => pattern.test(p)), `${text}: ${problems.join(" | ")}`);
};

test("the areas are the labels of the path map", () => {
  for (const area of ["runtime", "jit", "gc", "lib", "lsp", "vscode", "www", "docs", "ci", "packaging"]) assert.ok(AREAS.includes(area), area);
  assert.ok(!AREAS.includes("about"));
});

test("sound messages", () => {
  ok("fix(lib): hand a decoded chunk to the reader before the next line\n");
  ok("perf(jit): keep the loop counter in a register\n\nThe counter stayed in memory across the back edge. Now it stays in a register.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n");
  ok("docs(docs): describe `a; b` in the guide\n\nThe body may show `x; y` in code.\n\n    local a = 1; local b = 2\n");
  ok("fix(gc): mark the stack of a suspended coroutine\n# Please enter the commit message\n");
  ok("fixup! fix(gc): mark the stack\n");
  ok("test(tests): " + "x".repeat(59));
});

test("the first line", () => {
  bad("Fix the thing", /type\(area\): subject/);
  bad("fix: no area", /type\(area\): subject/);
  bad("fixes(lib): wrong type", /type "fixes"/);
  bad("fix(github): wrong area", /area "github"/);
  bad("fix(lib): Capital start", /lowercase/);
  bad("fix(lib): ends with a period.", /period/);
  bad("test(tests): " + "x".repeat(60), /72/);
  bad("fix(lib): subject\nbody without a blank line", /blank line/);
});

test("the body", () => {
  bad("fix(lib): subject\n\nOne clause; another clause.", /semicolon/);
  bad("fix(lib): subject\n\nA dash \u2014 here.", /dash/);
  bad("fix(lib): subject\n\nPorted from " + ["L", "u", "a", "u"].join("") + ".", /dialect/);
});
