// Tests of the path map and the planner. Run: mise run ci:test

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {test} from "node:test";
import {fileURLToPath} from "node:url";
import {CHECK_ORDER, GLOBAL_CHECKS, areasOf, globToRegExp, loadMap, plan, trackedFiles} from "./areas.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const map = loadMap();
const tracked = trackedFiles();
const CROSS = ["*", "riscv64-linux-musl", "loongarch64-linux-musl", "powerpc64le-linux-musl", "arm-linux-musleabihf", "s390x-linux-musl"];
const EXTRA = ["runtime", "freebsd", "android", "windows-arm64"];

const planFor = (...changed) => plan({map, changed, tracked});

test("globs", () => {
  assert.ok(globToRegExp("runtime/src/lib/**").test("runtime/src/lib/data/x.zig"));
  assert.ok(globToRegExp("a/**/b.zig").test("a/b.zig"));
  assert.ok(globToRegExp("a/**/b.zig").test("a/x/y/b.zig"));
  assert.ok(!globToRegExp("tools/*.js").test("tools/ci/x.js"));
  assert.ok(globToRegExp("x.{js,mjs}").test("x.mjs"));
  assert.ok(!globToRegExp("a.zig").test("a_zig"));
});

test("every tracked file belongs to an area", () => {
  const missing = tracked.filter((f) => areasOf(map, f).length === 0);
  assert.deepEqual(missing, []);
});

test("the map names only things that exist", () => {
  for (const area of map.areas) {
    for (const check of area.checks ?? []) assert.ok(CHECK_ORDER.includes(check) || GLOBAL_CHECKS.has(check), `${area.name}: check ${check}`);
    for (const bench of area.benches ?? []) {
      if (bench !== "{name}") assert.ok(fs.existsSync(path.join(ROOT, "tests/bench", bench)), `${area.name}: bench ${bench}`);
    }
    for (const t of area.tests ?? []) {
      if (t === "suite" || /[{*]/.test(t)) continue;
      assert.ok(fs.existsSync(path.join(ROOT, t)), `${area.name}: test ${t}`);
    }
    for (const target of area.cross ?? []) assert.ok(CROSS.includes(target), `${area.name}: cross ${target}`);
    for (const job of area.extra ?? []) assert.ok(EXTRA.includes(job), `${area.name}: extra ${job}`);
    for (const os of area.platforms ?? []) assert.ok(os in map.runners, `${area.name}: platform ${os}`);
    assert.ok(["allowed", "denied", "egregious", undefined].includes(area.contributor), `${area.name}: contributor`);
    for (const glob of area.paths) assert.ok(tracked.some((f) => globToRegExp(glob).test(f)), `${area.name}: ${glob} matches no file`);
  }
});

test("a library runs its own tests on Linux", () => {
  const p = planFor("runtime/src/lib/json.zig");
  assert.deepEqual(p.runtime.map((r) => r.os), ["linux"]);
  const [linux] = p.runtime;
  assert.ok(linux.tests.includes("../tests/conformance/json_test.lus"));
  assert.ok(!linux.suite);
  assert.ok(linux.checks.includes("corrupt"));
  assert.deepEqual(p.labels, ["lib"]);
});

test("code of each operating system runs on each runner", () => {
  const p = planFor("runtime/src/lib/watch.zig");
  assert.deepEqual(p.runtime.map((r) => r.os), ["linux", "macos", "windows"]);
  for (const r of p.runtime) assert.ok(r.tests.includes("watch_test.lus"));
});

test("the core of the runtime runs the suite", () => {
  const p = planFor("runtime/src/vm/gc.zig");
  const linux = p.runtime.find((r) => r.os === "linux");
  assert.ok(linux.suite);
  assert.ok(linux.checks.includes("stress"));
  assert.ok(p.labels.includes("gc"));
});

test("a conformance file runs itself, and a fixture runs the suite", () => {
  assert.equal(planFor("tests/conformance/serve_test.lus").runtime[0].tests, "../tests/conformance/serve_test.lus");
  const fixture = tracked.find((f) => f.startsWith("tests/conformance/fixtures/"));
  assert.ok(planFor(fixture).runtime[0].suite);
});

test("a path no area knows runs the fallback", () => {
  const p = planFor("runtime/src/new_thing.zig");
  assert.deepEqual(p.unmatched, ["runtime/src/new_thing.zig"]);
  assert.ok(p.runtime[0].suite);
  assert.equal(p.contributor.verdict, "denied");
});

test("documentation builds nothing of the runtime", () => {
  const p = planFor("spec/design/gc.md");
  assert.equal(p.runtime.length, 1);
  assert.deepEqual(p.runtime[0].checks, ["doc"]);
  assert.equal(p.runtime[0].tests, "");
});

test("contributor rules", () => {
  assert.equal(planFor("packages/site/src/manual/guide.mdx").contributor.verdict, "allowed");
  assert.equal(planFor("spec/stdlib/json/decode.md").contributor.verdict, "allowed");
  assert.equal(planFor("packages/site/src/pages/index.astro").contributor.verdict, "denied");
  assert.equal(planFor("runtime/build.zig.zon").contributor.verdict, "denied");
  assert.equal(planFor(".github/workflows/ci.yml").contributor.verdict, "egregious");
  assert.equal(planFor("AGENTS.md").contributor.verdict, "egregious");
  const mixed = planFor("runtime/src/lib/json.zig", "packaging/install/install.sh", "package.json");
  assert.equal(mixed.contributor.verdict, "egregious");
  assert.deepEqual(mixed.contributor.egregious, ["packaging/install/install.sh"]);
  assert.deepEqual(mixed.contributor.denied, ["package.json"]);
});

test("benchmarks follow the paths", () => {
  assert.deepEqual(planFor("tests/bench/fib.lus").benches, ["fib.lus"]);
  assert.ok(planFor("runtime/src/vm/gc.zig").benches.includes("gcpause.lus"));
});

test("cross builds follow the back ends", () => {
  const rv = planFor("runtime/src/jit/rv64.zig");
  assert.deepEqual(rv.targets, ["riscv64-linux-musl"]);
  assert.deepEqual(rv.full, ["cross", "emulated-link"]);
  const build = planFor("runtime/build.zig");
  assert.deepEqual(build.targets, []);
  assert.deepEqual(build.full, ["cross", "emulated-link"]);
  assert.deepEqual(planFor("runtime/src/jit/a64.zig").full, ["android", "windows-arm64"]);
  assert.deepEqual(planFor("runtime/src/link/macho.zig").full, ["cross", "emulated-link", "freebsd", "runtime"]);
  assert.deepEqual(planFor("runtime/src/lib/json.zig").full, []);
});

test("a coverage map adds the tests that reach a file", () => {
  const testmap = {"runtime/src/lib/glob.zig": ["tests/conformance/fs_test.lus"]};
  const p = plan({map, changed: ["runtime/src/lib/glob.zig"], tracked, testmap});
  assert.ok(p.runtime[0].tests.includes("../tests/conformance/fs_test.lus"));
});
