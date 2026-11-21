// Runs generated programs under every configuration of the runtime and
// reports each crash and each difference between configurations.
//
// Usage: node run.mjs [--count N] [--start SEED] [--jobs J] [--size S]
//                     [--configs a,b,c] [--lus PATH] [--stress PATH]
//                     [--timeout MS] [--out DIR] [--reduce] [--forever]
//                     [--minutes M] [--x64 PATH]
//
// Each finding is written to DIR (default tests/diff/findings) as the
// program, the outputs that disagree, and a reduced program when --reduce
// is given. --forever runs batches of N until stopped, or for M minutes
// with --minutes. The exit status is 1 when anything was found.

import { mkdirSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { generate } from "./gen.mjs";
import { defaultLus, judge, pool, root, runOne, selectConfigs, CONFIGS } from "./lib.mjs";
import { predicate, reduce } from "./reduce.mjs";

function arg(name, def) {
    const i = process.argv.indexOf(name);
    return i > 0 ? process.argv[i + 1] : def;
}
const flag = (name) => process.argv.includes(name);

const binaries = { lus: arg("--lus", defaultLus), stress: arg("--stress"), x64: arg("--x64") };
const count = Number(arg("--count", "100"));
const start = Number(arg("--start", String(Date.now() % 1000000000)));
const jobs = Number(arg("--jobs", String(Math.max(2, os.availableParallelism() - 1))));
const size = Number(arg("--size", "8"));
const timeout = Number(arg("--timeout", "30000"));
const outDir = arg("--out", path.join(root, "tests/diff/findings"));
const configs = selectConfigs(arg("--configs"), binaries);
const tmp = mkdtempSync(path.join(os.tmpdir(), "lus-diff-"));
const forever = flag("--forever");
const deadline = arg("--minutes") ? Date.now() + Number(arg("--minutes")) * 60000 : Infinity;

let found = 0, ran = 0, slow = 0;
const seen = new Set();

async function one(seed) {
    const src = generate(seed, size);
    const file = path.join(tmp, `p${seed}.lus`);
    writeFileSync(file, src);
    const results = await Promise.all(configs.map((c) => runOne(file, c, binaries, timeout)));
    // A timeout under load is often the machine and not the program, so a
    // configuration that timed out runs once more on its own.
    if (results.some((r) => r.signal === "timeout") && !results.every((r) => r.signal === "timeout")) {
        for (let i = 0; i < results.length; i++) {
            if (results[i].signal === "timeout") results[i] = await runOne(file, configs[i], binaries, timeout * 2);
        }
    }
    ran++;
    const findings = judge(results);
    rmSync(file, { force: true });
    if (!findings.length) return;
    const f = findings[0];
    if (f.kind === "slow") {
        slow++;
        console.log(`seed ${seed}: slow in every configuration`);
        return;
    }
    found++;
    const sig = f.kind === "crash" ? `${f.kind}:${f.what}` : `${f.kind}:${f.config}`;
    const fresh = !seen.has(sig);
    seen.add(sig);
    const summary = f.kind === "crash" ? `${f.config}: ${f.what}` : `${f.ref} vs ${f.config} at line ${f.what.line}: ${JSON.stringify(f.what.want)?.slice(0, 120)} / ${JSON.stringify(f.what.got)?.slice(0, 120)}`;
    console.log(`seed ${seed}: ${f.kind} ${summary}${fresh ? "" : " (seen)"}`);
    mkdirSync(outDir, { recursive: true });
    const base = path.join(outDir, `seed${seed}`);
    writeFileSync(base + ".lus", src);
    writeFileSync(base + ".txt", JSON.stringify({ seed, findings, outputs: results.map((r) => ({ config: r.config, code: r.code, signal: r.signal, stderr: r.stderr.slice(0, 4000) })) }, null, 2));
    if (flag("--reduce") && fresh) {
        const dir = mkdtempSync(path.join(tmp, "r"));
        let test;
        if (f.kind === "crash") {
            const cfg = CONFIGS.find((c) => c.name === f.config);
            const r0 = results.find((r) => r.config === f.config);
            test = predicate({ crash: cfg.name, binaries, timeout, dir, crashWhat: f.what });
            void r0;
        } else {
            test = predicate({ mismatch: `${f.ref},${f.config}`, binaries, timeout, dir });
        }
        const small = await reduce(src, test);
        writeFileSync(base + ".min.lus", small);
        console.log(`seed ${seed}: reduced to ${small.split("\n").length} lines in ${base}.min.lus`);
    }
}

do {
    const seeds = Array.from({ length: count }, (_, i) => start + i + ran);
    await pool(seeds, Math.max(1, Math.floor(jobs / Math.min(configs.length, 3))), one);
} while (forever && Date.now() < deadline);

rmSync(tmp, { recursive: true, force: true });
console.log(`${ran} programs, ${found} with findings, ${slow} slow, configurations: ${configs.map((c) => c.name).join(" ")}`);
process.exit(found ? 1 : 0);
