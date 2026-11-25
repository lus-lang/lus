import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { changelogNotes, dateChangelog, longDate, nextVersion, openChangelog, setPackageVersion, setZonVersion, zonVersion } from "./release-version.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "release-version.mjs");

const changelog = `# Changelog

## 2.0.0 (**WIP**)

**Release date:** TBD

Lus 2.0 is new.

### Language

- Added \`continue\`.

## 1.6.2

**Release date:** July 1, 2026

- Fixed a bug.
`;

test("versions", () => {
  assert.equal(nextVersion("2.0.0"), "2.1.0");
  assert.equal(nextVersion("2.9.3"), "2.10.0");
  assert.throws(() => nextVersion("2.0.0-dev"));
  assert.equal(longDate("2026-12-01"), "December 1, 2026");
  assert.throws(() => longDate("2026-13-01"));
});

test("build.zig.zon", () => {
  const zon = '.{\n    .name = .lus,\n    .version = "2.0.0-dev",\n    .minimum_zig_version = "0.17.1",\n}\n';
  assert.equal(zonVersion(zon), "2.0.0-dev");
  const out = setZonVersion(zon, "2.0.0");
  assert.equal(zonVersion(out), "2.0.0");
  assert.match(out, /minimum_zig_version = "0.17.1"/);
});

test("package.json keeps its layout", () => {
  const json = '{\n  "name": "lus-wasm",\n  "version": "2.0.0-dev",\n  "engines": {\n    "version": "x"\n  }\n}\n';
  const out = setPackageVersion(json, "2.0.0");
  assert.equal(JSON.parse(out).version, "2.0.0");
  assert.equal(JSON.parse(out).engines.version, "x");
  assert.equal(out.split("\n").length, json.split("\n").length);
});

test("changelog", () => {
  assert.equal(changelogNotes(changelog, "2.0.0"), "Lus 2.0 is new.\n\n### Language\n\n- Added `continue`.\n");
  const dated = dateChangelog(changelog, "2.0.0", "2026-12-01");
  assert.match(dated, /^## 2\.0\.0\n\n\*\*Release date:\*\* December 1, 2026\n/m);
  assert.match(dated, /\*\*Release date:\*\* July 1, 2026/);
  const opened = openChangelog(dated, "2.1.0");
  assert.ok(opened.startsWith("# Changelog\n\n## 2.1.0 (**WIP**)\n\n**Release date:** TBD\n\n## 2.0.0\n"));
  assert.throws(() => openChangelog(opened, "2.1.0"));
  assert.throws(() => changelogNotes(changelog, "3.0.0"));
});

function checkout() {
  const root = mkdtempSync(join(tmpdir(), "release-version-"));
  for (const d of ["runtime", "packages/wasm", "packages/vscode", "packages/site/src/news"]) mkdirSync(join(root, d), { recursive: true });
  writeFileSync(join(root, "runtime/build.zig.zon"), '.{\n    .version = "2.0.0-dev",\n}\n');
  writeFileSync(join(root, "packages/wasm/package.json"), '{\n  "name": "lus-wasm",\n  "version": "2.0.0-dev"\n}\n');
  writeFileSync(join(root, "packages/vscode/package.json"), '{\n  "name": "lus",\n  "version": "2.0.0",\n  "publisher": "lus"\n}\n');
  writeFileSync(join(root, "CHANGELOG.md"), changelog);
  return root;
}

test("release and next on a checkout", () => {
  const root = checkout();
  const run = (...args) => execFileSync(process.execPath, [script, ...args, "--root", root], { encoding: "utf8" });
  run("release", "--version", "2.0.0", "--date", "2026-12-01");
  assert.match(readFileSync(join(root, "runtime/build.zig.zon"), "utf8"), /\.version = "2\.0\.0",/);
  assert.equal(JSON.parse(readFileSync(join(root, "packages/wasm/package.json"), "utf8")).version, "2.0.0");
  assert.equal(JSON.parse(readFileSync(join(root, "packages/vscode/package.json"), "utf8")).version, "2.0.0");
  const news = readFileSync(join(root, "packages/site/src/news/changelog-2.0.0.md"), "utf8");
  assert.ok(news.startsWith("---\ntitle: Lus 2.0.0\ndate: 2026-12-01\n---\n\nLus 2.0 is new.\n"));
  assert.equal(run("notes", "--version", "2.0.0"), "Lus 2.0 is new.\n\n### Language\n\n- Added `continue`.\n");
  assert.equal(run("next", "--version", "2.0.0"), "2.1.0-dev\n");
  assert.match(readFileSync(join(root, "runtime/build.zig.zon"), "utf8"), /\.version = "2\.1\.0-dev",/);
  assert.equal(JSON.parse(readFileSync(join(root, "packages/wasm/package.json"), "utf8")).version, "2.1.0-dev");
  assert.ok(readFileSync(join(root, "CHANGELOG.md"), "utf8").startsWith("# Changelog\n\n## 2.1.0 (**WIP**)\n"));
});

test("a release needs the matching development version", () => {
  const root = checkout();
  assert.throws(() => execFileSync(process.execPath, [script, "release", "--version", "2.1.0", "--date", "2026-12-01", "--root", root], { stdio: "pipe" }));
});

test("the repository itself can be released", () => {
  const root = mkdtempSync(join(tmpdir(), "release-version-repo-"));
  const repo = join(here, "..");
  for (const f of ["runtime/build.zig.zon", "packages/wasm/package.json", "packages/vscode/package.json", "CHANGELOG.md"]) cpSync(join(repo, f), join(root, f), { recursive: true });
  mkdirSync(join(root, "packages/site/src/news"), { recursive: true });
  const version = execFileSync(process.execPath, ["-e", `process.stdout.write(require("fs").readFileSync(${JSON.stringify(join(repo, "runtime/build.zig.zon"))}, "utf8").match(/\\.version = "([^"]*)-dev"/)[1])`], { encoding: "utf8" });
  execFileSync(process.execPath, [script, "release", "--version", version, "--date", "2026-12-01", "--root", root]);
  execFileSync(process.execPath, [script, "next", "--version", version, "--root", root]);
});
