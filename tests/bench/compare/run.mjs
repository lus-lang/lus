#!/usr/bin/env node
// Cross-language benchmark harness. Runs every program directory under
// this folder on every runtime that has a file for it, checks that all
// runtimes print the same line, times them, and load tests the HTTP
// servers with oha. Writes results.json next to this file.
//
//   node run.mjs [--only a,b] [--runtimes a,b] [--runs N] [--size small]
//                [--http-duration 10s] [--http-warmup 2s] [--merge]

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../..");
const isMac = process.platform === "darwin";

// ---------------------------------------------------------------------
// Options

const opts = { runs: 5, size: "full", httpDuration: "10s", httpWarmup: "2s", merge: false };
{
    const argv = process.argv.slice(2);
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const next = () => {
            if (i + 1 >= argv.length) fail(`${a} needs a value`);
            return argv[++i];
        };
        if (a === "--only") opts.only = next().split(",");
        else if (a === "--runtimes") opts.runtimes = next().split(",");
        else if (a === "--runs") opts.runs = Math.max(1, parseInt(next(), 10));
        else if (a === "--size") opts.size = next();
        else if (a === "--http-duration") opts.httpDuration = next();
        else if (a === "--http-warmup") opts.httpWarmup = next();
        else if (a === "--merge") opts.merge = true;
        else if (a === "-h" || a === "--help") {
            console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 8).join("\n"));
            process.exit(0);
        } else fail(`unknown option ${a}`);
    }
    if (opts.size !== "full" && opts.size !== "small") fail("--size is full or small");
}

function fail(msg) {
    console.error(`run.mjs: ${msg}`);
    process.exit(2);
}

// ---------------------------------------------------------------------
// Runtimes

const lusBin = process.env.LUS || path.join(repo, "runtime/zig-out/bin/lus");
const ruby = fs.existsSync("/opt/homebrew/opt/ruby/bin/ruby") ? "/opt/homebrew/opt/ruby/bin/ruby" : "ruby";
// opcache needs a writable directory for its lock file.
const phpFlags = [
    "-d", "opcache.enable_cli=1",
    "-d", "opcache.jit=tracing",
    "-d", "opcache.jit_buffer_size=64M",
    "-d", `opcache.lockfile_path=${os.tmpdir()}`,
];

// Each runtime: the file extension it runs, how to build its command line,
// and how to read its version.
const RUNTIMES = [
    { id: "lus", name: "Lus", ext: "lus", cmd: (f, a) => [lusBin, f, ...a], version: () => first(run(lusBin, ["-v"])) },
    { id: "lua", name: "Lua", ext: "lua", cmd: (f, a) => ["lua5.5", f, ...a], version: () => first(run("lua5.5", ["-v"])).replace(/\s+Copyright.*/, "") },
    { id: "luajit", name: "LuaJIT", ext: "lua", cmd: (f, a) => ["luajit", f, ...a], version: () => first(run("luajit", ["-v"])).replace(/\s+--.*/, "") },
    {
        id: "luau",
        name: "Luau",
        ext: "luau",
        cmd: (f, a) => ["luau", "-O2", "--codegen", f, ...(a.length ? ["-a", ...a] : [])],
        version: luauVersion,
    },
    { id: "python", name: "Python", ext: "py", cmd: (f, a) => ["python3", f, ...a], version: () => first(run("python3", ["--version"])) },
    { id: "node", name: "Node.js", ext: "js", cmd: (f, a) => ["node", f, ...a], version: () => "Node.js " + first(run("node", ["--version"])) },
    { id: "bun", name: "Bun", ext: "js", cmd: (f, a) => ["bun", f, ...a], version: () => "Bun " + first(run("bun", ["--version"])) },
    {
        id: "ruby",
        name: "Ruby",
        ext: "rb",
        cmd: (f, a) => [ruby, "--yjit", f, ...a],
        version: () => first(run(ruby, ["--yjit", "--version"])).replace(/\s*\(.*?\)/, ""),
    },
    {
        id: "php",
        name: "PHP",
        ext: "php",
        cmd: (f, a) => ["php", ...phpFlags, f, ...a],
        version: () => first(run("php", ["-v"])).replace(/\s*\(.*$/, "") + " + JIT",
    },
];

function run(cmd, args, options = {}) {
    const r = spawnSync(cmd, args, { encoding: "utf8", ...options });
    if (r.error || r.status !== 0) return null;
    return (r.stdout || "") + (r.stderr || "");
}

function first(out) {
    if (out == null) throw new Error("not available");
    return out.trim().split("\n")[0].trim();
}

function luauVersion() {
    const which = run("sh", ["-c", "command -v luau"]);
    if (!which) throw new Error("not available");
    const real = fs.realpathSync(which.trim());
    const m = real.match(/\/luau\/([^/]+)\//);
    return `Luau ${m ? m[1] : "unknown"}`;
}

// ---------------------------------------------------------------------
// Device

function device() {
    if (isMac) {
        const sys = (k) => first(run("sysctl", ["-n", k]));
        return {
            device: {
                cpu: sys("machdep.cpu.brand_string"),
                cores: Number(sys("hw.ncpu")),
                memory_gb: Math.round(Number(sys("hw.memsize")) / 2 ** 30),
            },
            os: `macOS ${first(run("sw_vers", ["-productVersion"]))}`,
        };
    }
    const cpuinfo = fs.readFileSync("/proc/cpuinfo", "utf8");
    const model = (cpuinfo.match(/^model name\s*:\s*(.*)$/m) || [])[1] || os.cpus()[0]?.model || "unknown";
    const mem = Number((fs.readFileSync("/proc/meminfo", "utf8").match(/^MemTotal:\s*(\d+)/m) || [])[1] || 0);
    let osName = `Linux ${os.release()}`;
    try {
        const rel = fs.readFileSync("/etc/os-release", "utf8");
        const pretty = rel.match(/^PRETTY_NAME="?([^"\n]*)"?/m);
        if (pretty) osName = `${pretty[1]} (kernel ${os.release()})`;
    } catch {}
    return {
        device: { cpu: model.trim(), cores: os.cpus().length, memory_gb: Math.round(mem / 2 ** 20) },
        os: osName,
    };
}

// ---------------------------------------------------------------------
// Timing a single run

const timeArgs = isMac ? ["-l"] : ["-v"];

function timedRun(argv, cwd) {
    const t0 = process.hrtime.bigint();
    const r = spawnSync("/usr/bin/time", [...timeArgs, ...argv], {
        cwd,
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
    });
    const secs = Number(process.hrtime.bigint() - t0) / 1e9;
    const err = r.stderr || "";
    let rss = null;
    if (isMac) {
        const m = err.match(/(\d+)\s+maximum resident set size/);
        if (m) rss = Number(m[1]);
    } else {
        const m = err.match(/Maximum resident set size \(kbytes\):\s*(\d+)/);
        if (m) rss = Number(m[1]) * 1024;
    }
    const lines = (r.stdout || "").trim().split("\n");
    return {
        ok: !r.error && r.status === 0,
        line: lines[lines.length - 1] || "",
        secs,
        rss,
        stderr: err,
    };
}

function median(xs) {
    const s = [...xs].sort((a, b) => a - b);
    const m = s.length >> 1;
    return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const round = (x, d = 3) => (x == null ? null : Math.round(x * 10 ** d) / 10 ** d);
const mb = (bytes) => (bytes == null ? null : round(bytes / 2 ** 20, 1));

// The small size is a hundredth of the program's default size, read from
// the Python version's `else <default>` argument fallback.
function smallSize(dir, prog) {
    const files = fs.readdirSync(dir).sort((a, b) => Number(b.endsWith(".py")) - Number(a.endsWith(".py")));
    for (const f of files) {
        const src = fs.readFileSync(path.join(dir, f), "utf8");
        const m = src.match(/else\s+(\d{3,})\b/) || src.match(/\bor\s+(\d{3,})\b/);
        if (m) return String(Math.max(1, Math.round(Number(m[1]) / 100)));
    }
    console.warn(`  ${prog}: no default size found, running the small pass at full size`);
    return null;
}

// ---------------------------------------------------------------------
// Compute programs

function benchProgram(prog, runtimes) {
    const dir = path.join(here, prog);
    const cells = runtimes.filter((rt) => fs.existsSync(path.join(dir, `${prog}.${rt.ext}`)));
    const out = {};
    if (cells.length === 0) return out;
    const small = smallSize(dir, prog);
    const smallArgs = small ? [small] : [];
    const timeArgsFor = opts.size === "small" ? smallArgs : [];

    // Correctness: every runtime must print the same line at the small size.
    const lines = {};
    for (const rt of cells) {
        const r = timedRun(rt.cmd(`${prog}.${rt.ext}`, smallArgs), dir);
        lines[rt.id] = r.ok ? r.line : null;
        if (!r.ok) console.log(`  ${prog}/${rt.id}: failed\n${indent(r.stderr)}`);
    }
    const counts = {};
    for (const l of Object.values(lines)) if (l != null) counts[l] = (counts[l] || 0) + 1;
    const reference = Object.entries(counts).sort((a, b) => b[1] - a[1])[0]?.[0];
    const passing = [];
    for (const rt of cells) {
        if (lines[rt.id] != null && lines[rt.id] === reference) passing.push(rt);
        else {
            if (lines[rt.id] != null) console.log(`  ${prog}/${rt.id}: prints "${lines[rt.id]}", expected "${reference}"`);
            out[rt.id] = { best_s: null, median_s: null, peak_rss_mb: null, ok: false };
        }
    }

    // Timing: round-robin over the runtimes, rotating the start each round.
    const samples = Object.fromEntries(passing.map((rt) => [rt.id, []]));
    for (let r = 0; r < opts.runs; r++) {
        for (let k = 0; k < passing.length; k++) {
            const rt = passing[(k + r) % passing.length];
            const res = timedRun(rt.cmd(`${prog}.${rt.ext}`, timeArgsFor), dir);
            if (!res.ok) {
                console.log(`  ${prog}/${rt.id}: failed during timing\n${indent(res.stderr)}`);
                samples[rt.id] = null;
                continue;
            }
            if (samples[rt.id]) samples[rt.id].push(res);
        }
    }
    for (const rt of passing) {
        const s = samples[rt.id];
        if (!s || s.length === 0) {
            out[rt.id] = { best_s: null, median_s: null, peak_rss_mb: null, ok: false };
            continue;
        }
        const best = s.reduce((a, b) => (b.secs < a.secs ? b : a));
        out[rt.id] = {
            best_s: round(best.secs),
            median_s: round(median(s.map((x) => x.secs))),
            peak_rss_mb: mb(best.rss),
            ok: true,
        };
    }
    return out;
}

function indent(s) {
    return (s || "")
        .trim()
        .split("\n")
        .slice(-8)
        .map((l) => "      " + l)
        .join("\n");
}

// ---------------------------------------------------------------------
// HTTP servers

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function freePort() {
    return new Promise((resolve, reject) => {
        const s = net.createServer();
        s.once("error", reject);
        s.listen(0, "127.0.0.1", () => {
            const { port } = s.address();
            s.close(() => resolve(port));
        });
    });
}

function rssKb(pid) {
    const out = run("ps", ["-o", "rss=", "-p", String(pid)]);
    const n = out == null ? NaN : parseInt(out.trim(), 10);
    return Number.isFinite(n) ? n : null;
}

async function get(url) {
    const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
    return { status: res.status, type: res.headers.get("content-type") || "", body: await res.text() };
}

function runOha(args) {
    return new Promise((resolve) => {
        const p = spawn("oha", args, { stdio: ["ignore", "pipe", "pipe"] });
        let out = "";
        let err = "";
        p.stdout.on("data", (d) => (out += d));
        p.stderr.on("data", (d) => (err += d));
        p.on("close", (code) => resolve({ code, out, err }));
        p.on("error", (e) => resolve({ code: -1, out, err: String(e) }));
    });
}

async function benchServer(rt) {
    const dir = path.join(here, "http");
    const port = await freePort();
    const base = `http://127.0.0.1:${port}/`;
    const [cmd, ...args] = rt.cmd(`server.${rt.ext}`, [String(port)]);
    const child = spawn(cmd, args, { cwd: dir, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (d) => (stderr = (stderr + d).slice(-4000)));
    let exited = false;
    child.on("exit", () => (exited = true));
    const result = { rps: null, p50_ms: null, p99_ms: null, errors: null, idle_rss_mb: null, peak_rss_mb: null, ok: false };
    try {
        // Wait until it answers.
        const deadline = Date.now() + 15000;
        let ready = false;
        while (!ready && !exited && Date.now() < deadline) {
            try {
                ready = (await get(base)).status === 200;
            } catch {
                await sleep(100);
            }
        }
        if (!ready) throw new Error(`server did not answer\n${indent(stderr)}`);

        // Correctness: a JSON body with the counter, and 404 elsewhere.
        const a = await get(base);
        const b = await get(base);
        const ja = JSON.parse(a.body);
        const jb = JSON.parse(b.body);
        const nf = await get(base + "missing");
        if (!a.type.startsWith("application/json")) throw new Error(`content type is "${a.type}"`);
        if (ja.message !== "hello" || !Number.isInteger(ja.n) || jb.n !== ja.n + 1) throw new Error(`unexpected bodies ${a.body} ${b.body}`);
        if (nf.status !== 404) throw new Error(`GET /missing answered ${nf.status}`);

        await sleep(300);
        result.idle_rss_mb = round(rssKb(child.pid) / 1024, 1);

        await runOha(["-z", opts.httpWarmup, "-c", "64", "--no-tui", "--output-format", "quiet", base]);

        let peak = 0;
        const sampler = setInterval(() => {
            const kb = rssKb(child.pid);
            if (kb != null && kb > peak) peak = kb;
        }, 200);
        const load = await runOha(["-z", opts.httpDuration, "-c", "64", "--no-tui", "--output-format", "json", base]);
        clearInterval(sampler);
        const kb = rssKb(child.pid);
        if (kb != null && kb > peak) peak = kb;
        if (load.code !== 0) throw new Error(`oha failed\n${indent(load.err)}`);
        const j = JSON.parse(load.out);
        const ok200 = j.statusCodeDistribution?.["200"] || 0;
        let errors = 0;
        for (const [code, n] of Object.entries(j.statusCodeDistribution || {})) if (code !== "200") errors += n;
        // oha cancels the requests in flight when the duration ends and
        // reports them as "aborted due to deadline", which is not a
        // server error.
        for (const [kind, n] of Object.entries(j.errorDistribution || {})) if (!/aborted due to deadline/.test(kind)) errors += n;
        result.rps = Math.round(ok200 / j.summary.total);
        result.p50_ms = round(j.latencyPercentiles.p50 * 1000);
        result.p99_ms = round(j.latencyPercentiles.p99 * 1000);
        result.errors = errors;
        result.peak_rss_mb = round(peak / 1024, 1);
        result.ok = exited ? false : true;
    } catch (e) {
        console.log(`  http/${rt.id}: ${e.message}`);
    } finally {
        child.kill("SIGTERM");
        for (let i = 0; i < 20 && !exited; i++) await sleep(50);
        if (!exited) child.kill("SIGKILL");
    }
    return result;
}

// ---------------------------------------------------------------------
// Tables

function printTable(title, header, rows) {
    const widths = header.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
    const line = (cells) => cells.map((c, i) => (i === 0 ? String(c).padEnd(widths[i]) : String(c).padStart(widths[i]))).join("  ");
    console.log(`\n${title}`);
    console.log(line(header));
    console.log(widths.map((w) => "-".repeat(w)).join("  "));
    for (const r of rows) console.log(line(r));
}

// ---------------------------------------------------------------------
// Main

async function main() {
    const info = device();
    const runtimes = [];
    const runtimeInfo = {};
    for (const rt of RUNTIMES) {
        if (opts.runtimes && !opts.runtimes.includes(rt.id)) continue;
        try {
            const version = rt.version();
            runtimes.push(rt);
            runtimeInfo[rt.id] = { name: rt.name, version };
        } catch {
            console.log(`skipping ${rt.id}: not available`);
        }
    }
    console.log(`${info.device.cpu}, ${info.device.cores} cores, ${info.device.memory_gb} GB, ${info.os}`);
    for (const [id, r] of Object.entries(runtimeInfo)) console.log(`  ${id.padEnd(7)} ${r.version}`);

    const programs = fs
        .readdirSync(here, { withFileTypes: true })
        .filter((d) => d.isDirectory() && d.name !== "http" && !d.name.startsWith("."))
        .map((d) => d.name)
        .filter((p) => !opts.only || opts.only.includes(p))
        .sort();

    const results = {
        device: info.device,
        os: info.os,
        date: new Date().toISOString(),
        runs: opts.runs,
        size: opts.size,
        runtimes: runtimeInfo,
        programs: {},
        http: {},
    };
    const outFile = path.join(here, "results.json");
    if (opts.merge && fs.existsSync(outFile)) {
        const old = JSON.parse(fs.readFileSync(outFile, "utf8"));
        results.runtimes = { ...old.runtimes, ...runtimeInfo };
        results.programs = old.programs || {};
        results.http = old.http || {};
    }

    for (const prog of programs) {
        console.log(`\n${prog}`);
        results.programs[prog] = { ...(results.programs[prog] || {}), ...benchProgram(prog, runtimes) };
    }

    if (!opts.only || opts.only.includes("http")) {
        const servers = runtimes.filter((rt) => fs.existsSync(path.join(here, "http", `server.${rt.ext}`)));
        if (servers.length && !run("oha", ["--version"])) console.log("\nskipping http: oha not found");
        else if (servers.length) {
            console.log(`\nhttp (oha -z ${opts.httpDuration} -c 64)`);
            for (const rt of servers) {
                console.log(`  ${rt.id}`);
                results.http[rt.id] = await benchServer(rt);
            }
        }
    }

    fs.writeFileSync(outFile, JSON.stringify(results, null, 2) + "\n");

    const ids = Object.keys(results.runtimes).filter((id) => runtimes.some((rt) => rt.id === id));
    const progRows = Object.entries(results.programs).map(([p, cells]) => [
        p,
        ...ids.map((id) => {
            const c = cells[id];
            if (!c) return "";
            if (!c.ok) return "FAIL";
            return `${c.best_s.toFixed(3)}s ${c.peak_rss_mb}M`;
        }),
    ]);
    if (progRows.length) printTable(`best wall time and peak RSS (${opts.runs} runs, ${opts.size} size)`, ["program", ...ids], progRows);
    const httpRows = Object.entries(results.http).map(([id, h]) => [
        id,
        h.rps ?? "FAIL",
        h.p50_ms ?? "",
        h.p99_ms ?? "",
        h.errors ?? "",
        h.idle_rss_mb ?? "",
        h.peak_rss_mb ?? "",
    ]);
    if (httpRows.length) printTable("http", ["runtime", "req/s", "p50 ms", "p99 ms", "errors", "idle MB", "peak MB"], httpRows);
    console.log(`\nwrote ${path.relative(process.cwd(), outFile) || outFile}`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
