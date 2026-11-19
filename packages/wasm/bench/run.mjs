// Runs the benchmarks of tests/bench on lus.wasm under Node, with the JIT
// off and on, and prints the best wall time of each.
//
// Usage: node bench/run.mjs [runs] [names...]
//
// Each run executes a whole benchmark in a fresh state of one instance
// per configuration, and the configurations alternate, so that they share
// the conditions of the machine. "jit" includes everything the JIT costs:
// emitting modules inside lus.wasm and compiling and instantiating them in
// the host. The last columns report how many modules the JIT made for one
// run of the benchmark and how long the host spent compiling and
// instantiating them.

import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLus } from "../src/node.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const benchDir = path.resolve(here, "../../../tests/bench");

const args = process.argv.slice(2);
const runs = args.length && /^\d+$/.test(args[0]) ? Number(args.shift()) : 5;
const names = args.length
  ? args
  : readdirSync(benchDir)
      .filter((f) => f.endsWith(".lus"))
      .map((f) => f.slice(0, -4))
      .sort();

const configs = [
  { name: "off", env: { LUS_JIT: "off" } },
  { name: "jit", env: { LUS_JIT: "on" } },
];

const hosts = {};
for (const c of configs) hosts[c.name] = await loadLus(undefined, { env: c.env });

const rows = [];
for (const name of names) {
  const source = readFileSync(path.join(benchDir, `${name}.lus`), "utf8");
  const best = {};
  let jitInfo = null;
  let failed = null;
  for (let i = 0; i < runs && !failed; i++) {
    for (const c of configs) {
      const lus = hosts[c.name];
      const before = lus.jit ? { ...lus.jit.stats } : null;
      const start = performance.now();
      const r = lus.run(source, { chunkname: `@${name}.lus` });
      const ms = performance.now() - start;
      if (!r.ok) {
        failed = `${c.name}: ${r.error}`;
        break;
      }
      best[c.name] = Math.min(best[c.name] ?? Infinity, ms);
      if (c.name === "jit" && lus.jit && i === 0) {
        const s = lus.jit.stats;
        jitInfo = {
          modules: s.modules - before.modules,
          kb: (s.bytes - before.bytes) / 1024,
          compileMs: s.compileMs - before.compileMs,
          instantiateMs: s.instantiateMs - before.instantiateMs,
        };
      }
    }
  }
  if (failed) {
    rows.push([name, "-", "-", "-", failed]);
    continue;
  }
  rows.push([
    name,
    (best.off / 1000).toFixed(3),
    (best.jit / 1000).toFixed(3),
    (best.off / best.jit).toFixed(2),
    `${jitInfo.modules}`,
    jitInfo.kb.toFixed(0),
    jitInfo.compileMs.toFixed(2),
    jitInfo.instantiateMs.toFixed(2),
  ]);
}

console.log(`Best of ${runs} runs, wall seconds, Node ${process.version}.\n`);
console.log("| benchmark | off | jit | speedup | modules | KiB | compile ms | instantiate ms |");
console.log("|---|---:|---:|---:|---:|---:|---:|---:|");
for (const r of rows) console.log(`| ${r.join(" | ")} |`);
