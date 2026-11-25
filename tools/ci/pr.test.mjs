// Tests of the required fields of a pull request. Run: mise run ci:test

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {test} from "node:test";
import {fileURLToPath} from "node:url";
import {checkPr, parseBody} from "./pr.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const template = fs.readFileSync(path.join(ROOT, ".github/PULL_REQUEST_TEMPLATE.md"), "utf8");
const fill = (kind, agent) => template.replace("## Kind\n", `## Kind\n\n${kind}\n`).replace("## Agent disclosure\n", `## Agent disclosure\n\n${agent}\n`);
const claude = "Agent: Claude\nModel: claude-opus-5-5\nHarness: Claude Code";
const trailer = {sha: "a".repeat(40), message: "fix(lib): x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"};
const plain = {sha: "b".repeat(40), message: "fix(lib): y\n"};

test("the empty template fails on both fields", () => {
  const r = parseBody(template);
  assert.equal(r.kind, null);
  assert.equal(r.agents, null);
  assert.equal(r.problems.length, 2);
});

test("a filled template", () => {
  const r = checkPr(fill("bug", "none"), [plain]);
  assert.deepEqual(r.problems, []);
  assert.equal(r.kind, "bug");
  assert.deepEqual(r.agents, []);
});

test("kinds", () => {
  assert.equal(parseBody(fill("`perf`", "none")).kind, "perf");
  const feature = parseBody(fill("feature", "none"));
  assert.ok(feature.rejected);
  assert.equal(feature.problems.length, 1);
  const two = parseBody(fill("bug\nperf", "none"));
  assert.ok(!two.rejected);
  assert.equal(two.problems.length, 1);
});

test("a known harness needs its trailer", () => {
  assert.deepEqual(checkPr(fill("bug", claude), [trailer, plain]).problems, []);
  assert.match(checkPr(fill("bug", claude), [plain]).problems[0], /keep the trailer of Claude Code/);
});

test("a trailer needs the disclosure", () => {
  assert.match(checkPr(fill("bug", "none"), [trailer]).problems[0], /name Claude Code in your Agent disclosure/);
});

test("another harness is recorded", () => {
  const r = checkPr(fill("docs", "Agent: Other\nModel: m-1\nHarness: Some Editor"), [plain]);
  assert.deepEqual(r.problems, []);
  assert.equal(r.notes.length, 1);
  assert.equal(r.agents[0].harness, "Some Editor");
});

test("an incomplete disclosure", () => {
  const r = parseBody(fill("bug", "Agent: Claude\nHarness: Claude Code"));
  assert.match(r.problems[0], /add the model of agent 1/);
});
