#!/usr/bin/env node
// Measures the benchmarks of tests/bench/perf-map.json and compares two
// measurements.
//
//   node tools/ci/perf.mjs run --lus BIN --out FILE [--runs N] [--only a.lus,b.lus]
//   node tools/ci/perf.mjs ab --base BIN --head BIN --out FILE [--runs N] [--only ...]
//   node tools/ci/perf.mjs compare --current FILE --baseline FILE [--name NAME] [--summary FILE]
//
// `run` runs each benchmark N times and records the wall time and the peak
// resident memory of each run, with their median and median absolute
// deviation. `ab` runs two binaries in turn on the same runner, alternating
// their order each round, so the noise of a shared runner falls on both.
// `compare` prints a Markdown table and lists the regressions as JSON. A
// benchmark regresses when its median grows past its own threshold in the
// perf map, which comes from its measured noise, and the growth also
// exceeds a multiple of the larger deviation of the two measurements
// (tools/ci/perf.json), so the noise of one runner never counts. --only
// takes the ids of the perf map, such as fib or compare/json.

import {spawnSync} from "node:child_process";
import {execFileSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, "tools/ci/perf.json"), "utf8"));
export const PERF_MAP = JSON.parse(fs.readFileSync(path.join(ROOT, "tests/bench/perf-map.json"), "utf8"));

export function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export function mad(xs) {
  const m = median(xs);
  return median(xs.map((x) => Math.abs(x - m)));
}

export function benches(only) {
  const all = Object.keys(PERF_MAP.benchmarks).filter((id) => !CONFIG.skip.includes(id)).sort();
  return only ? all.filter((id) => only.includes(id)) : all;
}

// The command of a benchmark. A Lus file runs on the binary, and any other
// command finds the binary in LUS, as tests/bench/compare/run.mjs does.
function command(lus, id) {
  const bench = PERF_MAP.benchmarks[id];
  if (bench.run.endsWith(".lus")) return {argv: [lus, path.join(ROOT, bench.run)], env: process.env};
  return {argv: bench.run.split(/\s+/), env: {...process.env, LUS: lus}};
}

// Runs one benchmark once and returns {time, rss} in seconds and bytes, or
// null when it fails or runs past the limit.
function once(lus, id) {
  const linux = process.platform === "linux";
  const report = path.join(os.tmpdir(), `lus-perf-${process.pid}.txt`);
  const timeArgs = linux ? ["-f", "%M", "-o", report] : ["-l"];
  const {argv, env} = command(lus, id);
  const start = process.hrtime.bigint();
  const r = spawnSync("/usr/bin/time", [...timeArgs, ...argv], {
    cwd: path.join(ROOT, PERF_MAP.benchmarks[id].cwd),
    env,
    encoding: "utf8",
    timeout: CONFIG.timeout_seconds * 1000,
    stdio: ["ignore", "ignore", "pipe"],
  });
  const time = Number(process.hrtime.bigint() - start) / 1e9;
  if (r.status !== 0) return null;
  let rss;
  if (linux) {
    rss = Number(fs.readFileSync(report, "utf8").trim().split("\n").pop()) * 1024;
  } else {
    rss = Number(/(\d+)\s+maximum resident set size/.exec(r.stderr)?.[1] ?? NaN);
  }
  return {time, rss};
}

function summarize(samples) {
  const out = {};
  for (const key of ["time", "rss"]) {
    const xs = samples.map((s) => s[key]).filter(Number.isFinite);
    out[key] = {median: median(xs), mad: mad(xs), samples: xs};
  }
  return out;
}

function describe(lus) {
  let commit = "";
  try {
    commit = execFileSync("git", ["rev-parse", "HEAD"], {cwd: ROOT, encoding: "utf8"}).trim();
  } catch {}
  let version = "";
  try {
    version = execFileSync(lus, ["-v"], {encoding: "utf8"}).trim();
  } catch {}
  return {schema: 1, commit, version, date: new Date().toISOString(), runner: {os: `${os.type()} ${os.release()}`, arch: os.arch(), cpu: os.cpus()[0]?.model ?? "", cores: os.cpus().length}};
}

export function measure(binaries, list, runs) {
  const samples = binaries.map(() => Object.fromEntries(list.map((b) => [b, []])));
  const failed = binaries.map(() => new Set());
  // A benchmark that runs in a few milliseconds runs more rounds, since the
  // start of the process weighs on each one.
  const rounds = (bench) => (PERF_MAP.benchmarks[bench]?.short ? runs * CONFIG.short_factor : runs);
  for (let round = 0; round < runs * CONFIG.short_factor; round++) {
    for (const bench of list) {
      if (round >= rounds(bench)) continue;
      // The order of the binaries alternates each round.
      const order = binaries.map((_, i) => i);
      if (round % 2) order.reverse();
      for (const i of order) {
        const r = once(binaries[i], bench);
        if (r) samples[i][bench].push(r);
        else failed[i].add(bench);
      }
    }
  }
  return binaries.map((_, i) => ({
    benches: Object.fromEntries(list.filter((b) => !failed[i].has(b)).map((b) => [b, summarize(samples[i][b])])),
    failed: [...failed[i]],
  }));
}

// Compares a measurement with a baseline. Returns the rows of the table
// and the regressions.
export function compare(current, baseline, config = CONFIG) {
  const rows = [];
  const regressions = [];
  for (const [bench, cur] of Object.entries(current.benches)) {
    const base = baseline.benches?.[bench];
    if (!base) continue;
    const row = {bench};
    for (const key of ["time", "rss"]) {
      const t = {...config.thresholds[key], ratio: PERF_MAP.benchmarks[bench]?.[key] ?? config.thresholds[key].ratio};
      const b = base[key].median;
      const c = cur[key].median;
      const noise = Math.max(base[key].mad, cur[key].mad, t.floor);
      const ratio = b > 0 ? c / b : 1;
      const regressed = ratio - 1 > t.ratio && c - b > config.mads * noise;
      row[key] = {base: b, current: c, ratio, regressed};
      if (regressed) regressions.push({bench, key, base: b, current: c, ratio});
    }
    rows.push(row);
  }
  return {rows, regressions};
}

function fmt(key, v) {
  return key === "time" ? `${(v * 1000).toFixed(1)} ms` : `${(v / 1048576).toFixed(1)} MB`;
}

export function table({rows, regressions}, name) {
  const lines = [`### ${name}`, "", "| benchmark | time | change | memory | change |", "| --- | ---: | ---: | ---: | ---: |"];
  for (const r of rows) {
    const cell = (key) => {
      const pct = ((r[key].ratio - 1) * 100).toFixed(1);
      return `${fmt(key, r[key].current)} | ${r[key].ratio >= 1 ? "+" : ""}${pct}%${r[key].regressed ? " **regressed**" : ""}`;
    };
    lines.push(`| ${r.bench} | ${cell("time")} | ${cell("rss")} |`);
  }
  lines.push("", regressions.length ? `${regressions.length} regressions past the threshold.` : "No regression past the threshold.");
  return lines.join("\n");
}

function args(argv) {
  const a = {};
  for (let i = 1; i < argv.length; i += 2) a[argv[i].replace(/^--/, "")] = argv[i + 1];
  return a;
}

function main() {
  const argv = process.argv.slice(2);
  const a = args(argv);
  const runs = Number(a.runs ?? CONFIG.runs);
  const only = a.only ? a.only.split(",").filter(Boolean) : null;
  if (argv[0] === "run" && a.lus && a.out) {
    const [result] = measure([path.resolve(a.lus)], benches(only), runs);
    fs.writeFileSync(a.out, JSON.stringify({...describe(a.lus), runs, ...result}, null, 1) + "\n");
    return;
  }
  if (argv[0] === "ab" && a.base && a.head && a.out) {
    const [base, head] = measure([path.resolve(a.base), path.resolve(a.head)], benches(only), runs);
    const info = describe(a.head);
    const cmp = compare(head, base);
    fs.writeFileSync(a.out, JSON.stringify({...info, runs, base, head, regressions: cmp.regressions}, null, 1) + "\n");
    console.log(table(cmp, "This change against its base"));
    return;
  }
  if (argv[0] === "compare" && a.current && a.baseline) {
    const cmp = compare(JSON.parse(fs.readFileSync(a.current, "utf8")), JSON.parse(fs.readFileSync(a.baseline, "utf8")));
    const text = table(cmp, a.name ?? "Against the baseline");
    console.log(text);
    if (a.summary) fs.appendFileSync(a.summary, text + "\n\n");
    if (a.regressions) fs.writeFileSync(a.regressions, JSON.stringify(cmp.regressions) + "\n");
    return;
  }
  console.error("usage: perf.mjs run --lus BIN --out FILE | ab --base BIN --head BIN --out FILE | compare --current FILE --baseline FILE");
  process.exit(2);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
