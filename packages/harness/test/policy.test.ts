// Run: node --experimental-strip-types --test test/*.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { diffStats, parseDiff, parseTestSummary, testFailures } from "../src/parse.ts";
import {
  baseGrants,
  grantFor,
  isBase,
  lockZigBuild,
  lusInvocation,
  miseLockPolicy,
  parseDenial,
  scanPledges,
  semicolons,
} from "../src/policy.ts";

test("scanPledges reads literal pledges and skips comments, rejections, and seal", () => {
  const source = [
    'pledge("fs:read=./data/*", \'network:http\')',
    '-- pledge("exec")',
    'pledge("~env", "seal")',
    "pledge(`fs:write=$dir`)",
    "--[[ pledge(\"ffi\") ]]",
  ].join("\n");
  assert.deepEqual(scanPledges(source), ["fs:read=./data/*", "network:http"]);
});

test("parseDenial reads the permission and its value", () => {
  const err = "lus: p.lus:3: permission \"network:http\" denied for 'https://example.com/a'\nstack traceback:";
  assert.deepEqual(parseDenial(err), { name: "network:http", value: "https://example.com/a" });
  assert.deepEqual(parseDenial('permission "exec" denied for os.execute'), { name: "exec", value: undefined });
  assert.equal(parseDenial("all good"), undefined);
});

test("grantFor narrows network grants to the host and makes paths absolute", () => {
  assert.equal(grantFor({ name: "network:http", value: "https://api.example.com/v1/x" }, "/p"), "network:http=api.example.com");
  assert.equal(grantFor({ name: "fs:write", value: "out/a.txt" }, "/p"), "fs:write=/p/out/a.txt");
  assert.equal(grantFor({ name: "exec" }, "/p"), "exec");
});

test("isBase accepts reads inside the project and load, nothing else", () => {
  for (const g of baseGrants("/p")) assert.ok(isBase(g, "/p"), g);
  assert.ok(isBase("fs:read=./data/*", "/p"));
  assert.ok(!isBase("fs:read=/etc/*", "/p"));
  assert.ok(!isBase("fs:read", "/p"));
  assert.ok(!isBase("fs:write=/p/*", "/p"));
  assert.ok(!isBase("network", "/p"));
});

test("lusInvocation finds lus runs in bash commands", () => {
  assert.deepEqual(lusInvocation("lus main.lus --units x"), { grants: [], script: "main.lus" });
  assert.deepEqual(lusInvocation("cd app && lus -Pfs:read -P network main.lus"), { grants: ["fs:read", "network"], script: "main.lus" });
  assert.deepEqual(lusInvocation("lus run --pledge=env main.lus"), { grants: ["env"], script: "main.lus" });
  assert.deepEqual(lusInvocation("lus -e 'print(1)'"), { grants: [], script: undefined });
  assert.equal(lusInvocation("lus test ."), undefined);
  assert.equal(lusInvocation("lus fmt --write ."), undefined);
  assert.equal(lusInvocation("echo lus"), undefined);
  assert.deepEqual(lusInvocation("LUS_JIT=off ./zig-out/bin/lus x.lus"), { grants: [], script: "x.lus" });
});

test("lockZigBuild routes zig build through the lock with at most two jobs", () => {
  const lock = "sh /r/tools/with-build-lock.sh";
  assert.equal(lockZigBuild("zig build -Doptimize=ReleaseSafe", "/r"), `${lock} zig build -j2 -Doptimize=ReleaseSafe`);
  assert.equal(lockZigBuild("cd runtime && zig build -j8 test", "/r"), `cd runtime && ${lock} zig build -j2 test`);
  assert.equal(lockZigBuild("zig build -j1", "/r"), `${lock} zig build -j1`);
  assert.equal(lockZigBuild("sh tools/with-build-lock.sh zig build -j2", "/r"), undefined);
  assert.equal(lockZigBuild("zig fmt src", "/r"), undefined);
});

test("miseLockPolicy wraps unlocked builds unless a dependency takes the lock", () => {
  const tasks = [
    { name: "build", run: ["sh ../tools/with-build-lock.sh zig build -j2"] },
    { name: "test", run: ["zig build -j2 test", "zig-out/bin/lus test ../tests"] },
    { name: "diff", depends: ["build"], run: "lus run.lus" },
    { name: "both", depends: ["build"], run: "zig build -j2 x" },
    { name: "docs", run: "node tools/build-llms.js" },
  ];
  assert.equal(miseLockPolicy(tasks, "build"), "self");
  assert.equal(miseLockPolicy(tasks, "test"), "wrap");
  assert.equal(miseLockPolicy(tasks, "diff"), "self");
  assert.equal(miseLockPolicy(tasks, "both"), "unsafe");
  assert.equal(miseLockPolicy(tasks, "docs"), "none");
});

test("semicolons flags prose and ignores code, front matter, and entities", () => {
  const text = ["---", "title: a; b", "---", "One clause; another.", "`a; b` is code.", "```lus", "local a = 1; local b = 2", "```", "A&nbsp;space."].join("\n");
  assert.deepEqual(semicolons("x.md", text), ["x.md:4: semicolon in prose"]);
});

test("parseDiff reads the display diff of the edit tool", () => {
  const diff = [" 1 a", "-2 b", "+2 c", "+3 d", "   ...", " 9 z"].join("\n");
  assert.deepEqual(parseDiff(diff).map((l) => l.kind), ["ctx", "del", "add", "add", "gap", "ctx"]);
  assert.deepEqual(diffStats(diff), { added: 2, removed: 1 });
});

test("parseTestSummary and testFailures read the lus test report", () => {
  const out = [
    "FAIL m_test.lus (1 passed, 1 failed, 2 ms)",
    "  FAIL fails_test",
    "       m_test.lus:2: assertion failed: 1 == 2",
    "",
    "1 files, 1 passed, 1 failed, 0 skipped",
  ].join("\n");
  assert.deepEqual(parseTestSummary(out), { files: 1, passed: 1, failed: 1, skipped: 0, fileErrors: 0 });
  assert.deepEqual(testFailures(out), ["FAIL fails_test", "  m_test.lus:2: assertion failed: 1 == 2"]);
  assert.equal(parseTestSummary("1 files, 0 passed, 0 failed, 0 skipped, 1 file with errors")?.fileErrors, 1);
});
