#!/usr/bin/env node
// Chooses what CI runs for a change, from the changed paths and the map
// in tools/ci/areas.json.
//
//   node tools/ci/areas.mjs plan --base SHA [--head SHA] [--testmap FILE]
//   node tools/ci/areas.mjs plan --files a.zig b.lus
//   node tools/ci/areas.mjs unmatched
//   node tools/ci/areas.mjs codeowners [--write]
//
// `plan` prints the plan as JSON. Under GitHub Actions it also writes each
// field to $GITHUB_OUTPUT, one line per field with the value as JSON.
// `unmatched` prints every tracked file that no area matches and fails
// when there is one. `codeowners` checks that the paths .github/CODEOWNERS
// lists for contributors to leave alone are those the map denies, and
// rewrites that section with --write.
//
// A path takes the union of the tests, checks, platforms, and labels of
// every area it matches, and the benchmarks that tests/bench/perf-map.json
// maps it to. Its contributor rule is the
// strictest among them: allowed, then denied, then egregious. A path that
// matches no area takes the fallback of the map. The plan never runs
// nothing for a change to the runtime, because the fallback runs the
// conformance suite.

import {execFileSync} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const RULES = ["allowed", "denied", "egregious"];
// Checks that run once in a job of their own, apart from the runtime rows:
// the web job of full.yml, and the tests of these tools.
export const GLOBAL_CHECKS = new Set(["web", "ci"]);
// The order in which a runtime row lists its checks, which is the order of
// the steps of the targeted job in ci.yml.
export const CHECK_ORDER = ["unit", "debug", "version", "doc", "direct", "stress", "wasm", "install", "diff", "oom", "corrupt", "syntax", "crash", "faults"];

// Turns a glob into a regular expression over a path relative to the root.
// `**` matches any run of directories, `*` any run within one name, `?`
// one character, and `{a,b}` either word.
export function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      i++;
      if (glob[i + 1] === "/") {
        i++;
        re += "(?:.*/)?";
      } else {
        re += ".*";
      }
    } else if (c === "*") {
      re += "[^/]*";
    } else if (c === "?") {
      re += "[^/]";
    } else if (c === "{") {
      const end = glob.indexOf("}", i);
      re += "(?:" + glob.slice(i + 1, end).split(",").map(escape).join("|") + ")";
      i = end;
    } else {
      re += escape(c);
    }
  }
  return new RegExp("^" + re + "$");
}

function escape(text) {
  return text.replace(/[.+^$()|[\]\\]/g, "\\$&");
}

export function loadMap(file = path.join(ROOT, "tools/ci/areas.json")) {
  const map = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const area of map.areas) {
    area.match = area.paths.map(globToRegExp);
    area.skip = (area.exclude ?? []).map(globToRegExp);
  }
  return map;
}

// tests/bench/perf-map.json, which the speed work keeps: every benchmark
// with its command and thresholds, and the source globs that reach each.
export function loadPerfMap(file = path.join(ROOT, "tests/bench/perf-map.json")) {
  const perf = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const entry of perf.paths) entry.match = entry.globs.map(globToRegExp);
  return perf;
}

// The ids of the benchmarks that a change to a file reaches. A glob whose
// benchmarks read "all" reaches every one, and one that reads "changed"
// reaches the benchmark whose own files changed.
export function benchesOf(perfMap, file) {
  const ids = new Set();
  for (const entry of perfMap.paths) {
    if (!entry.match.some((re) => re.test(file))) continue;
    if (entry.benches === "all") {
      for (const id of Object.keys(perfMap.benchmarks)) ids.add(id);
    } else if (entry.benches === "changed") {
      for (const [id, bench] of Object.entries(perfMap.benchmarks)) {
        if (bench.run === file || (bench.cwd !== "tests/bench" && bench.cwd !== "." && file.startsWith(bench.cwd + "/"))) ids.add(id);
      }
    } else {
      for (const id of entry.benches) ids.add(id);
    }
  }
  return ids;
}

export function areasOf(map, file) {
  return map.areas.filter((area) => area.match.some((re) => re.test(file)) && !area.skip.some((re) => re.test(file)));
}

export function trackedFiles() {
  // New files that no ignore rule covers count too, as in lint-repo.js.
  const listed = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], {cwd: ROOT, encoding: "utf8"});
  return [...new Set(listed.split("\0").filter(Boolean))];
}

export function changedFiles(base, head = "HEAD") {
  // Without rename detection a moved file is a deletion and an addition,
  // so both of its paths count.
  return execFileSync("git", ["diff", "--name-only", "--no-renames", `${base}...${head}`], {cwd: ROOT, encoding: "utf8"})
    .split("\n")
    .filter(Boolean);
}

function stricter(a, b) {
  return RULES.indexOf(a) >= RULES.indexOf(b) ? a : b;
}

// Expands one entry of an area's tests for a changed file to test paths,
// or to the word "suite".
function expandTests(entry, file, tracked) {
  if (entry === "suite") return ["suite"];
  if (entry === "{path}") return /_test\.lus$/.test(file) ? [file] : ["suite"];
  const stem = path.basename(file).replace(/\.[^.]*$/, "");
  const pattern = entry.replaceAll("{stem}", stem);
  if (!/[*?{]/.test(pattern)) return [pattern];
  const re = globToRegExp(pattern);
  return tracked.filter((f) => re.test(f));
}

// Builds the plan for the changed files. `tracked` lists the files of the
// head commit, and `testmap`, when given, maps a runtime source file to the
// conformance files whose runs reach it (tools/ci/testmap.mjs).
export function plan({map, changed, tracked, testmap = null, perfMap = loadPerfMap()}) {
  const existing = new Set(tracked);
  const rows = new Map();
  const labels = new Set();
  const benches = new Set();
  const cross = new Set();
  const extra = new Set();
  const global = new Set();
  const contributor = {verdict: "allowed", denied: [], egregious: []};
  const unmatched = [];

  const row = (os) => {
    if (!rows.has(os)) rows.set(os, {os, runner: map.runners[os], checks: new Set(), tests: new Set(), suite: false});
    return rows.get(os);
  };

  for (const file of changed) {
    let areas = areasOf(map, file);
    if (areas.length === 0) {
      unmatched.push(file);
      areas = [{...map.fallback, name: "fallback", labels: [map.fallback.label]}];
    }
    let rule = "allowed";
    const filePlatforms = [...new Set(areas.flatMap((area) => area.platforms ?? ["linux"]))];
    for (const area of areas) {
      rule = stricter(rule, area.contributor ?? "allowed");
      for (const label of area.labels ?? []) labels.add(label);
      for (const target of area.cross ?? []) cross.add(target);
      for (const job of area.extra ?? []) extra.add(job);
      for (const check of area.checks ?? []) {
        if (GLOBAL_CHECKS.has(check)) global.add(check);
      }
      // The checks of an area run on its own platforms.
      for (const os of area.platforms ?? ["linux"]) {
        const r = row(os);
        for (const check of area.checks ?? []) if (!GLOBAL_CHECKS.has(check)) r.checks.add(check);
      }
      // Its tests run on every platform of the file, so a library whose
      // code differs per system runs its own tests on each.
      for (const os of filePlatforms) {
        const r = row(os);
        for (const entry of area.tests ?? []) {
          for (const test of expandTests(entry, file, tracked)) {
            if (test === "suite") r.suite = true;
            else if (existing.has(test) || fs.existsSync(path.join(ROOT, test))) r.tests.add(test);
          }
        }
        if (testmap && file.startsWith("runtime/src/") && testmap[file]) {
          for (const test of testmap[file]) if (existing.has(test)) r.tests.add(test);
        }
      }
    }
    for (const id of benchesOf(perfMap, file)) benches.add(id);
    if (rule === "denied") contributor.denied.push(file);
    if (rule === "egregious") contributor.egregious.push(file);
    contributor.verdict = stricter(contributor.verdict, rule);
  }

  // A row with nothing to run is dropped. A row with any work builds lus,
  // so it runs the unit tests too when it reaches the runtime sources.
  const runtime = [];
  for (const os of ["linux", "macos", "windows"]) {
    const r = rows.get(os);
    if (!r) continue;
    if (!r.suite && r.tests.size === 0 && r.checks.size === 0) continue;
    const tests = r.suite ? map.suite : [...r.tests].sort();
    runtime.push({
      os,
      runner: r.runner,
      checks: CHECK_ORDER.filter((c) => r.checks.has(c)),
      suite: r.suite,
      // Paths relative to runtime/, where the job runs `lus test`.
      tests: tests.map((t) => "../" + t).join(" "),
    });
  }

  // The jobs of full.yml that the change needs, and its cross targets. An
  // empty list of targets asks full.yml for every target.
  const targets = cross.has("*") ? [] : [...cross].sort();
  const full = [...extra];
  if (cross.size) full.push("cross", "emulated-link");
  if (global.has("web")) full.push("web");
  return {
    labels: [...labels].sort(),
    runtime,
    full: full.sort(),
    targets,
    ci: global.has("ci"),
    benches: [...benches].sort(),
    contributor,
    unmatched,
  };
}

// The contributor rule of one file, with the fallback for a file that no
// area knows.
export function ruleOf(map, file) {
  const areas = areasOf(map, file);
  if (areas.length === 0) return map.fallback.contributor;
  return areas.reduce((rule, area) => stricter(rule, area.contributor ?? "allowed"), "allowed");
}

const OWNERS_BEGIN = "# BEGIN paths that contributors leave alone, written by `node tools/ci/areas.mjs codeowners --write`";
const OWNERS_END = "# END paths that contributors leave alone";

// Lists the paths that contributors may not change, as CODEOWNERS
// patterns: each directory whose files are all denied or egregious, at
// the highest such level, and each such file outside those directories.
export function restrictedPatterns(map, tracked) {
  const restricted = new Set(tracked.filter((f) => ruleOf(map, f) !== "allowed"));
  const allowedDirs = new Set();
  for (const f of tracked) {
    if (restricted.has(f)) continue;
    const parts = f.split("/");
    for (let i = 1; i < parts.length; i++) allowedDirs.add(parts.slice(0, i).join("/"));
  }
  const patterns = new Set();
  for (const f of restricted) {
    const parts = f.split("/");
    let pattern = "/" + f;
    for (let i = 1; i < parts.length; i++) {
      const dir = parts.slice(0, i).join("/");
      if (!allowedDirs.has(dir)) {
        pattern = "/" + dir + "/";
        break;
      }
    }
    patterns.add(pattern);
  }
  return [...patterns].sort();
}

// Rewrites the generated section of .github/CODEOWNERS and returns the
// new text. The owner of each pattern is the owner of the `*` line.
export function codeowners(text, patterns) {
  const owner = /^\*\s+(.+)$/m.exec(text)?.[1].trim() ?? "";
  const width = Math.max(...patterns.map((p) => p.length)) + 2;
  const section = [OWNERS_BEGIN, ...patterns.map((p) => p.padEnd(width) + owner), OWNERS_END].join("\n");
  const begin = text.indexOf(OWNERS_BEGIN);
  const end = text.indexOf(OWNERS_END);
  if (begin >= 0 && end > begin) return text.slice(0, begin) + section + text.slice(end + OWNERS_END.length);
  return text.replace(/\n*$/, "\n\n") + section + "\n";
}

function parseArgs(argv) {
  const args = {_: []};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--write") continue;
    if (a === "--files") {
      args.files = argv.slice(i + 1);
      break;
    }
    if (a.startsWith("--")) args[a.slice(2)] = argv[++i];
    else args._.push(a);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const map = loadMap();
  const tracked = trackedFiles();
  if (args._[0] === "unmatched") {
    const missing = tracked.filter((f) => areasOf(map, f).length === 0);
    for (const f of missing) console.log(f);
    process.exit(missing.length ? 1 : 0);
  }
  if (args._[0] === "codeowners") {
    const file = path.join(ROOT, ".github/CODEOWNERS");
    const text = fs.readFileSync(file, "utf8");
    const next = codeowners(text, restrictedPatterns(map, tracked));
    if (process.argv.includes("--write")) fs.writeFileSync(file, next);
    else if (next !== text) {
      console.error(".github/CODEOWNERS disagrees with tools/ci/areas.json, so run node tools/ci/areas.mjs codeowners --write");
      process.exit(1);
    }
    process.exit(0);
  }
  if (args._[0] !== "plan") {
    console.error("usage: areas.mjs plan (--base SHA [--head SHA] | --files PATH...) [--testmap FILE] | areas.mjs unmatched");
    process.exit(2);
  }
  // A push that starts a branch has no earlier commit to compare with, and
  // GitHub reports its base as a run of zeros. The plan then treats every
  // file under runtime/src as changed, which comes to the fallback suite
  // and the checks of the runtime.
  let changed;
  if (args.files) changed = args.files;
  else if (!args.base || /^0+$/.test(args.base)) changed = ["runtime/src/vm/interp.zig"];
  else changed = changedFiles(args.base, args.head ?? "HEAD");
  let testmap = null;
  if (args.testmap && fs.existsSync(args.testmap)) testmap = JSON.parse(fs.readFileSync(args.testmap, "utf8")).sources;
  const result = plan({map, changed, tracked, testmap});
  console.log(JSON.stringify(result, null, 2));
  if (process.env.GITHUB_OUTPUT) {
    const lines = Object.entries(result).map(([k, v]) => `${k}=${JSON.stringify(v)}`);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.join("\n") + "\n");
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
