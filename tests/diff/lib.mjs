// Shared parts of the differential runner and the reducer: the
// configurations of the runtime, running one program under one of them,
// and comparing the results.

import { spawn } from "node:child_process";
import { rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const root = path.resolve(here, "../..");
export const defaultLus = path.join(root, "runtime/zig-out/bin/lus");

// Every configuration must print the same trace as the interpreter of
// the same architecture. The
// thresholds of 2 and 3 make functions tier up after their first calls,
// in the middle of the loops that drive them, which the eager modes never
// do. `stress` names a binary built with `-Dgc-stress` and `-Dgc-verify`,
// and `x64` a binary built for x86-64, which runs its own JIT backend.
export const CONFIGS = [
    { name: "off", env: { LUS_JIT: "off" } },
    { name: "default", env: {} },
    { name: "eager", env: { LUS_JIT: "eager" } },
    { name: "baseline-hot", env: { LUS_JIT: "baseline", LUS_JIT_THRESHOLD: "2" } },
    { name: "opt-eager", env: { LUS_JIT: "opt-eager" } },
    { name: "opt-hot", env: { LUS_JIT_THRESHOLD: "2", LUS_JIT_OPT_THRESHOLD: "3" } },
    { name: "opt-direct", env: { LUS_JIT: "opt-eager", LUS_JIT_DIRECT: "1024" } },
    { name: "stress-eager", env: { LUS_JIT: "eager" }, binary: "stress" },
    { name: "stress-opt", env: { LUS_JIT_THRESHOLD: "2", LUS_JIT_OPT_THRESHOLD: "3" }, binary: "stress" },
    // The program after `lus fmt`, which must keep its meaning. Positions
    // in messages change with the layout, so they are masked.
    { name: "fmt", env: { LUS_JIT: "off" }, fmt: true },
    { name: "x64-off", env: { LUS_JIT: "off" }, binary: "x64" },
    { name: "x64-eager", env: { LUS_JIT: "eager" }, binary: "x64" },
    { name: "x64-opt-eager", env: { LUS_JIT: "opt-eager" }, binary: "x64" },
    { name: "x64-opt-hot", env: { LUS_JIT_THRESHOLD: "2", LUS_JIT_OPT_THRESHOLD: "3" }, binary: "x64" },
];

export function selectConfigs(names, binaries) {
    let list = CONFIGS.filter((c) => !c.binary || binaries[c.binary]);
    if (names) {
        const want = new Set(names.split(","));
        list = CONFIGS.filter((c) => want.has(c.name));
    }
    return list;
}

// Runs `file` under `config` and resolves with the exit status, the
// signal, and both outputs. A run longer than `timeout` milliseconds is
// killed and reported as a timeout.
export async function runOne(file, config, binaries, timeout = 20000) {
    if (config.fmt) {
        const formatted = file.replace(/\.lus$/, ".fmt.lus");
        const f = await runArgs(binaries.lus, ["fmt", file], {}, timeout);
        if (f.code !== 0) return { config: config.name, code: f.code, signal: f.signal, stdout: "", stderr: "lus fmt failed: " + f.stderr, fmt: true };
        writeFileSync(formatted, f.stdout, "latin1");
        const res = await runOne(formatted, { ...config, fmt: false }, binaries, timeout);
        rmSync(formatted, { force: true });
        return { ...res, config: config.name, fmt: true };
    }
    const bin = config.binary ? binaries[config.binary] : binaries.lus;
    const res = await runArgs(bin, [file], config.env, timeout * (config.binary === "stress" ? 4 : 1));
    return { ...res, config: config.name, binary: config.binary ?? "lus" };
}

function runArgs(bin, args, extraEnv, timeout) {
    return new Promise((resolve) => {
        const env = { ...process.env, ...extraEnv };
        if (!extraEnv.LUS_JIT) delete env.LUS_JIT;
        const child = spawn(bin, args, { env, stdio: ["ignore", "pipe", "pipe"] });
        const out = [], err = [];
        let size = 0, timedOut = false;
        const limit = 64 << 20;
        child.stdout.on("data", (d) => { size += d.length; if (size < limit) out.push(d); });
        child.stderr.on("data", (d) => { size += d.length; if (size < limit) err.push(d); });
        const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, timeout);
        child.on("close", (code, signal) => {
            clearTimeout(timer);
            resolve({
                code,
                signal: timedOut ? "timeout" : signal,
                stdout: Buffer.concat(out).toString("latin1"),
                stderr: Buffer.concat(err).toString("latin1"),
            });
        });
    });
}

// A crash is a signal, an abort, or a panic message, whatever the output.
export function crashOf(res) {
    if (res.signal === "timeout") return "timeout";
    const panic = /panic: ([^\n]*)/.exec(res.stderr);
    if (panic) return "panic: " + panic[1].replace(/0x[0-9a-f]+/g, "0x?");
    if (res.signal) return "signal " + res.signal;
    if (res.code !== 0 && res.code !== 1) return "exit " + res.code;
    if (/Segmentation fault|Illegal instruction|Bus error|AddressSanitizer|ThreadSanitizer/.test(res.stderr)) return "fault";
    if (/error\(gpa\)|memory address .* leaked/.test(res.stderr)) return "leak";
    return null;
}

// The first line where two results differ, for the report.
const maskPositions = (s) => s.replace(/[^\s"]*\.lus:\d+:/g, "@:");

export function firstDifference(a, b) {
    const norm = a.fmt || b.fmt ? maskPositions : (s) => s;
    const x = norm(a.stdout + "\n--stderr--\n" + a.stderr + "\n--exit " + a.code).split("\n");
    const y = norm(b.stdout + "\n--stderr--\n" + b.stderr + "\n--exit " + b.code).split("\n");
    const n = Math.max(x.length, y.length);
    for (let i = 0; i < n; i++) {
        if (x[i] !== y[i]) return { line: i + 1, want: x[i], got: y[i] };
    }
    return null;
}

// Classifies the results of one program. Every crash is a finding. So is
// every configuration whose output differs from the first configuration.
export function judge(results) {
    const findings = [];
    // A program that times out everywhere is slow, not wrong.
    if (results.every((r) => r.signal === "timeout")) return [{ kind: "slow", config: "all", what: "timeout" }];
    for (const r of results) {
        const c = crashOf(r);
        if (c) findings.push({ kind: "crash", config: r.config, what: c });
    }
    // Each run compares with the first run of the same architecture. The
    // gc-stress build shares the native reference. Two architectures differ
    // in their math library and in the sign of a NaN, so they are never
    // compared with each other.
    const arch = (r) => (r.binary === "x64" ? "x64" : "native");
    const refs = new Map();
    for (const r of results) if (!refs.has(arch(r))) refs.set(arch(r), r);
    for (const r of results) {
        const ref = refs.get(arch(r));
        if (r === ref || crashOf(ref) || crashOf(r)) continue;
        const d = firstDifference(ref, r);
        if (d) findings.push({ kind: "mismatch", config: r.config, ref: ref.config, what: d });
    }
    return findings;
}

// A pool that runs at most `n` promises at once.
export async function pool(items, n, fn) {
    const out = new Array(items.length);
    let next = 0;
    async function worker() {
        while (next < items.length) {
            const i = next++;
            out[i] = await fn(items[i], i);
        }
    }
    await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
    return out;
}
