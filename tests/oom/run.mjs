// Sweeps allocation failures over Lus programs.
//
// The runner needs a binary built with `zig build -Dfail-alloc=true`. For
// each file it counts the allocations of a clean run, then runs the file
// again once for each allocation number N in the sweep with
// `LUS_FAIL_ALLOC=N`, which fails that one allocation. A run may fail its
// tests or end with "not enough memory". It must not crash, panic, leak,
// or hang. Each distinct crash is reported once, with the smallest N that
// produced it, so the report reads as a list of bugs.
//
// Test files run through `lus test --run-one`, the child mode of `lus
// test`, so that the failure lands in the process that runs the tests.
// Any other file runs as a script.
//
// Usage: node run.mjs [--lus PATH] [--samples K] [--sticky] [--jobs J]
//                     [--timeout MS] [files or directories...]
// --samples 0 sweeps every N. The default samples 40 values of N per file.

import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");

function arg(name, def) {
    const i = process.argv.indexOf(name);
    return i > 0 ? process.argv[i + 1] : def;
}
const lus = path.resolve(arg("--lus", path.join(root, "runtime/zig-out-oom/bin/lus")));
const samples = Number(arg("--samples", "40"));
const sticky = process.argv.includes("--sticky");
const jobs = Number(arg("--jobs", String(Math.max(2, os.availableParallelism() - 1))));
const timeout = Number(arg("--timeout", "30000"));
const valued = new Set(["--lus", "--samples", "--jobs", "--timeout"]);
const operands = process.argv.slice(2).filter((a, i, all) => !a.startsWith("--") && !valued.has(all[i - 1]));

function collect(p, out) {
    const st = statSync(p);
    if (st.isDirectory()) {
        for (const e of readdirSync(p).sort()) {
            if (e === "fixtures") continue;
            const q = path.join(p, e);
            if (statSync(q).isDirectory() || e.endsWith(".lus")) collect(q, out);
        }
    } else out.push(path.resolve(p));
    return out;
}
const files = (operands.length ? operands : [path.join(root, "tests/conformance")]).flatMap((p) => collect(p, []));

function run(file, env) {
    const isTest = file.endsWith("_test.lus");
    const argv = isTest ? ["test", "--run-one", file] : [file];
    const cwd = mkdtempSync(path.join(os.tmpdir(), "lus-oom-"));
    return new Promise((resolve) => {
        const child = spawn(lus, argv, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "", stderr = "", timedOut = false;
        child.stdout.on("data", (d) => { if (stdout.length < 1 << 20) stdout += d; });
        child.stderr.on("data", (d) => { if (stderr.length < 1 << 20) stderr += d; });
        const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, timeout);
        child.on("close", (code, signal) => {
            clearTimeout(timer);
            rmSync(cwd, { recursive: true, force: true });
            resolve({ code, signal: timedOut ? "timeout" : signal, stdout, stderr });
        });
    });
}

// The kind of a bad run, with the place it happened, or null for a run
// that ended cleanly.
function verdict(res) {
    const where = () => {
        const m = /\n(\S*src\/[^\s:]+:\d+):\d+: 0x[0-9a-f]+ in (\S+)/.exec(res.stderr);
        return m ? ` at ${m[2]} (${m[1].replace(/.*\/src\//, "src/")})` : "";
    };
    if (res.signal === "timeout") return "hang";
    const panic = /panic: ([^\n]*)/.exec(res.stderr);
    if (panic) return `panic: ${panic[1].replace(/\d{3,}/g, "N")}${where()}`;
    if (res.signal) return `signal ${res.signal}${where()}`;
    if (/leaked/.test(res.stderr)) return `leak${where()}`;
    // Status 2 is the test runner's own report of a file that could not load.
    if (res.code !== 0 && res.code !== 1 && res.code !== 2) return `exit ${res.code}${where()}`;
    return null;
}

function pick(count) {
    if (samples === 0 || count <= samples) return Array.from({ length: count }, (_, i) => i + 1);
    const out = new Set();
    // The first allocations build the state, which every run shares, so
    // they get a dense sample. The rest are spread over the run.
    for (let i = 1; i <= Math.min(10, count); i++) out.add(i);
    while (out.size < samples) out.add(1 + Math.floor(Math.random() * count));
    return [...out].sort((a, b) => a - b);
}

const bugs = new Map();
let runs = 0;

async function pool(items, n, fn) {
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
        while (next < items.length) { const i = next++; await fn(items[i]); }
    }));
}

const work = [];
await pool(files, jobs, async (file) => {
    const res = await run(file, { LUS_FAIL_ALLOC: "count" });
    const m = /lus: (\d+) allocations/.exec(res.stderr);
    const bad = verdict(res);
    if (bad || !m) {
        console.log(`${path.relative(root, file)}: the clean run ${bad ?? "printed no allocation count"}`);
        return;
    }
    for (const n of pick(Number(m[1]))) work.push({ file, n });
});

await pool(work, jobs, async ({ file, n }) => {
    const res = await run(file, { LUS_FAIL_ALLOC: sticky ? `${n}+` : String(n) });
    runs++;
    const bad = verdict(res);
    if (!bad) return;
    const prev = bugs.get(bad);
    if (!prev || n < prev.n) bugs.set(bad, { file, n, count: (prev?.count ?? 0) + 1, stderr: res.stderr });
    else prev.count++;
});

for (const [what, b] of bugs) {
    console.log(`\n${what}\n  ${b.count} runs, first: LUS_FAIL_ALLOC=${b.n}${sticky ? "+" : ""} ${path.relative(root, b.file)}`);
}
console.log(`\n${files.length} files, ${runs} runs, ${bugs.size} distinct failures`);
process.exit(bugs.size ? 1 : 0);
