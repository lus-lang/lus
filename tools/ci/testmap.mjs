#!/usr/bin/env node
// Builds the map from runtime source files to the conformance files whose
// runs reach them, which tools/ci/areas.mjs adds to the tests of a change.
//
//   node tools/ci/testmap.mjs --lus runtime/zig-out-cov/bin/lus --out testmap.json [--jobs 4] [--only a_test.lus,b_test.lus]
//
// The binary must come from a `-Dcoverage=true` build. Each conformance
// file runs alone with LUS_COVERAGE set to a directory of its own, and the
// report of that directory, exported with LUS_COVERAGE_EXPORT, lists the
// source positions the file reached (runtime/src/coverage.zig). The
// positions that a trivial test file reaches are left out first, since
// every run reaches them. The nightly workflow runs this and uploads the
// map as an artifact.
//
// A source file that more than half of the conformance files reach is
// left out of the map. The path map already sends such a file to the
// whole suite, and leaving it out keeps the map small.

import {spawn} from "node:child_process";
import {execFileSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function parseArgs(argv) {
  const args = {jobs: "4", timeout: "300"};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith("--")) args[argv[i].slice(2)] = argv[++i];
  return args;
}

function run(cmd, argv, opts, seconds) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, {...opts, stdio: ["ignore", "ignore", "pipe"]});
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), seconds * 1000);
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({code, err});
    });
  });
}

// Maps a position of the export to a path from the root of the repository.
export function sourceOf(position) {
  const file = position.slice(0, position.lastIndexOf(":", position.lastIndexOf(":") - 1));
  const norm = file.replaceAll("\\", "/");
  const at = norm.lastIndexOf("runtime/src/");
  if (at >= 0) return norm.slice(at);
  if (norm.startsWith("src/")) return "runtime/" + norm;
  if (!norm.startsWith("/")) return "runtime/src/" + norm;
  return null;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.lus || !args.out) {
    console.error("usage: testmap.mjs --lus COVERAGE_BINARY --out FILE [--jobs N] [--timeout SECONDS] [--only FILES]");
    process.exit(2);
  }
  const lus = path.resolve(args.lus);
  const tests = fs
    .readdirSync(path.join(ROOT, "tests/conformance"))
    .filter((f) => f.endsWith("_test.lus"))
    .filter((f) => !args.only || args.only.split(",").includes(f))
    .map((f) => `tests/conformance/${f}`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "lus-testmap-"));
  const reached = new Map();
  let next = 0;
  let failed = 0;

  // Runs one test file under coverage and returns the positions it
  // reached, or null when the report fails.
  async function positions(test, dir) {
    fs.mkdirSync(dir);
    const env = {...process.env, LUS_COVERAGE: dir, LUS_BIN: lus, LUS_JIT: "off"};
    // A failing test still reached what it reached, so the map keeps it.
    const result = await run(lus, ["test", "-P", "bytecode", test], {cwd: path.join(ROOT, "runtime"), env}, Number(args.timeout));
    if (result.code !== 0) {
      failed++;
      console.error(`${test}: exit ${result.code}`);
    }
    const out = path.join(dir, "export.txt");
    const report = await run(lus, [], {cwd: path.join(ROOT, "runtime"), env: {...process.env, LUS_COVERAGE_REPORT: dir, LUS_COVERAGE_EXPORT: out}}, Number(args.timeout));
    if (report.code !== 0 || !fs.existsSync(out)) {
      console.error(`${test}: no coverage export (${report.err.trim()})`);
      return null;
    }
    return fs.readFileSync(out, "utf8").split("\n").filter(Boolean);
  }

  // Every run opens every library and starts the test runner, which
  // reaches some code of each library. A test file counts as reaching a
  // source file only through positions that this trivial test leaves
  // unreached.
  const trivial = path.join(work, "trivial_test.lus");
  fs.writeFileSync(trivial, "local function trivial_test()\n    assert(1 + 1 == 2)\nend\n");
  const baseline = new Set((await positions(trivial, path.join(work, "baseline"))) ?? []);
  if (baseline.size === 0) {
    console.error("the trivial test reached nothing, so the coverage build does not work");
    process.exit(1);
  }

  async function worker() {
    while (next < tests.length) {
      const index = next++;
      const test = tests[index];
      const list = await positions(path.join(ROOT, test), path.join(work, String(index)));
      if (!list) continue;
      const sources = new Set();
      for (const position of list) {
        if (baseline.has(position)) continue;
        const source = sourceOf(position);
        if (source) sources.add(source);
      }
      for (const source of sources) {
        if (!reached.has(source)) reached.set(source, []);
        reached.get(source).push(test);
      }
      console.error(`${index + 1}/${tests.length} ${test}: ${sources.size} files`);
    }
  }

  await Promise.all(Array.from({length: Number(args.jobs)}, worker));
  fs.rmSync(work, {recursive: true, force: true});

  const sources = {};
  for (const [source, list] of [...reached].sort()) {
    if (list.length * 2 > tests.length) continue;
    sources[source] = list.sort();
  }
  const commit = execFileSync("git", ["rev-parse", "HEAD"], {cwd: ROOT, encoding: "utf8"}).trim();
  fs.writeFileSync(args.out, JSON.stringify({commit, generated: new Date().toISOString(), tests: tests.length, failed, sources}, null, 1) + "\n");
  console.error(`${Object.keys(sources).length} source files mapped, ${reached.size - Object.keys(sources).length} left to the suite`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
