// Tests of the decisions of the contribution gate. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import {decide, knownAuthors} from "./gate.mjs";

const now = Date.parse("2026-11-25T00:00:00Z");
const old = {created_at: "2020-01-01T00:00:00Z"};
const young = {created_at: "2026-01-01T00:00:00Z"};
const body = "## Kind\n\nbug\n\n## Agent disclosure\n\nnone\n";
const signed = {sha: "a".repeat(40), commit: {message: "fix(lib): x\n", verification: {verified: true, reason: "valid"}}};
const unsigned = {sha: "b".repeat(40), commit: {message: "fix(lib): y\n", verification: {verified: false, reason: "unsigned"}}};
const pr = (extra = {}) => ({kind: "pr", item: {user: {login: "someone"}, author_association: "CONTRIBUTOR", body, ...extra}, user: old, commits: [signed], files: ["runtime/src/lib/json.zig"], known: new Set(), now});

test("known authors", () => {
  assert.deepEqual([...knownAuthors("# comment\nAlice\n  bob # note\n\n")], ["alice", "bob"]);
  assert.ok(decide({...pr(), known: new Set(["someone"])}).exempt);
  assert.ok(decide(pr({author_association: "OWNER"})).exempt);
});

test("a sound pull request passes", () => {
  const d = decide(pr());
  assert.equal(d.passed, true);
  assert.equal(d.action, "pass");
  assert.deepEqual(d.labels, []);
});

test("young accounts and unsigned commits fail", () => {
  const d = decide({...pr(), user: young, commits: [signed, unsigned]});
  assert.equal(d.action, "fail");
  assert.equal(d.failures.length, 2);
  assert.deepEqual(d.labels, ["gate-failed"]);
});

test("a feature is closed, and an egregious path is locked", () => {
  assert.equal(decide(pr({body: body.replace("bug", "feature")})).action, "reject");
  assert.equal(decide({...pr(), files: [".github/workflows/ci.yml", "runtime/src/lib/json.zig"]}).action, "lock");
  const denied = decide({...pr(), files: ["runtime/build.zig.zon"]});
  assert.equal(denied.action, "fail");
  assert.match(denied.failures[0], /build\.zig\.zon/);
});

test("an issue needs a signing key", () => {
  const issue = {kind: "issue", item: {user: {login: "someone"}, author_association: "NONE"}, user: old, keys: 0, known: new Set(), now};
  assert.equal(decide(issue).action, "fail");
  assert.equal(decide({...issue, keys: 1}).action, "pass");
});
