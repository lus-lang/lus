// Shrinks a Lus program while a finding stays.
//
// The reducer reads the program as a tree of lines by their indentation,
// which is how `lus fmt` and the generator lay programs out. It tries to
// delete each statement with everything nested in it, then to replace a
// block statement by its body, and repeats until no change keeps the
// finding. The finding is a crash with the same message in one
// configuration, or a difference between two configurations.
//
// Usage: node reduce.mjs FILE --crash CONFIG [--out FILE]
//        node reduce.mjs FILE --mismatch REF,CONFIG [--out FILE]
// Options: --lus PATH, --stress PATH, --timeout MS.

import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { CONFIGS, crashOf, defaultLus, firstDifference, runOne } from "./lib.mjs";

const CLOSERS = /^(end\b|end\)|until\b|else\b|elseif\b|\}\)?$)/;

function indentOf(line) {
    return line.length - line.trimStart().length;
}

// The lines a statement at `i` covers: the line itself, every line nested
// deeper below it, and the closing lines at its own indentation (`else`,
// `elseif`, and `end`) with what they nest.
function extent(lines, i) {
    const ind = indentOf(lines[i]);
    let j = i + 1;
    for (;;) {
        while (j < lines.length && (lines[j].trim() === "" || indentOf(lines[j]) > ind)) j++;
        if (j < lines.length && indentOf(lines[j]) === ind && CLOSERS.test(lines[j].trim())) {
            const closer = lines[j].trim();
            j++;
            if (/^(else|elseif)\b/.test(closer)) continue;
            break;
        }
        break;
    }
    return j;
}

export async function reduce(source, interesting, log = () => {}) {
    let lines = source.split("\n");
    let tests = 0;
    const tryLines = async (cand) => {
        tests++;
        return (await interesting(cand.join("\n"))) ? cand : null;
    };
    let changed = true;
    while (changed) {
        changed = false;
        // Delete runs of top-level statements in halves, then single
        // statements at every depth from the end of the file backwards.
        for (let chunk = Math.max(1, lines.length >> 1); chunk >= 1; chunk >>= 1) {
            for (let i = 0; i < lines.length; ) {
                if (CLOSERS.test(lines[i].trim())) { i++; continue; }
                let j = i, k = 0;
                while (j < lines.length && k < chunk && !(CLOSERS.test(lines[j].trim()) && indentOf(lines[j]) <= indentOf(lines[i]))) {
                    if (indentOf(lines[j]) < indentOf(lines[i])) break;
                    j = extent(lines, j);
                    k++;
                }
                if (j === i) { i++; continue; }
                const cand = await tryLines([...lines.slice(0, i), ...lines.slice(j)]);
                if (cand) { lines = cand; changed = true; log(`${lines.length} lines after ${tests} tests`); }
                else i = chunk > 1 ? j : i + 1;
            }
        }
        // Replace a block statement by its body.
        for (let i = 0; i < lines.length; i++) {
            const end = extent(lines, i);
            if (end - i < 2) continue;
            const ind = indentOf(lines[i]);
            const body = [];
            for (let k = i + 1; k < end; k++) {
                const t = lines[k];
                if (indentOf(t) === ind && CLOSERS.test(t.trim())) continue;
                body.push(t.slice(Math.min(4, indentOf(t) - ind > 0 ? 4 : 0)));
            }
            const cand = await tryLines([...lines.slice(0, i), ...body, ...lines.slice(end)]);
            if (cand) { lines = cand; changed = true; log(`${lines.length} lines after ${tests} tests`); }
        }
        // Shorten long lines by replacing parenthesized subexpressions with
        // a small literal, which often keeps the finding.
        for (let i = 0; i < lines.length; i++) {
            for (const lit of ["0", "1", "nil", '""']) {
                let improved = true;
                while (improved) {
                    improved = false;
                    const line = lines[i];
                    const spans = parenSpans(line);
                    for (const [a, b] of spans) {
                        if (b - a < 3) continue;
                        const cand = [...lines];
                        cand[i] = line.slice(0, a) + lit + line.slice(b + 1);
                        if (await tryLines(cand)) { lines = cand; improved = true; changed = true; break; }
                    }
                }
            }
        }
    }
    return lines.join("\n");
}

// The spans of balanced parentheses in a line, longest first.
function parenSpans(line) {
    const out = [], stack = [];
    let quote = null;
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
        if (c === '"' || c === "'" || c === "`") { quote = c; continue; }
        if (c === "(") stack.push(i);
        else if (c === ")" && stack.length) out.push([stack.pop(), i]);
    }
    return out.sort((x, y) => (y[1] - y[0]) - (x[1] - x[0]));
}

function arg(name, def) {
    const i = process.argv.indexOf(name);
    return i > 0 ? process.argv[i + 1] : def;
}

// An interestingness test for a crash in one configuration or a
// difference between two.
export function predicate({ crash, mismatch, binaries, timeout, dir, crashWhat }) {
    let n = 0;
    return async (src) => {
        const file = path.join(dir, `cand${n++ % 4}.lus`);
        writeFileSync(file, src);
        if (crash) {
            const cfg = CONFIGS.find((c) => c.name === crash);
            const res = await runOne(file, cfg, binaries, timeout);
            const c = crashOf(res);
            if (c === null || (crashWhat && c !== crashWhat)) return false;
            // A timeout counts only while the interpreter still finishes,
            // or the reducer would keep any infinite loop.
            if (c === "timeout") return crashOf(await runOne(file, CONFIGS[0], binaries, timeout)) === null;
            return true;
        }
        const [a, b] = mismatch.split(",").map((nm) => CONFIGS.find((c) => c.name === nm));
        const [ra, rb] = await Promise.all([runOne(file, a, binaries, timeout), runOne(file, b, binaries, timeout)]);
        if (crashOf(ra) || crashOf(rb)) return false;
        return firstDifference(ra, rb) !== null;
    };
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const file = process.argv[2];
    const binaries = { lus: arg("--lus", defaultLus), stress: arg("--stress"), x64: arg("--x64") };
    const timeout = Number(arg("--timeout", "10000"));
    const dir = mkdtempSync(path.join(os.tmpdir(), "lus-reduce-"));
    const crash = arg("--crash");
    const mismatch = arg("--mismatch");
    const source = readFileSync(file, "utf8");
    let crashWhat = null;
    if (crash) {
        const res = await runOne(file, CONFIGS.find((c) => c.name === crash), binaries, timeout);
        crashWhat = crashOf(res);
        if (!crashWhat) { console.error("the program does not crash in " + crash); process.exit(2); }
        console.error("reducing " + crashWhat);
    }
    const test = predicate({ crash, mismatch, binaries, timeout, dir, crashWhat });
    if (!(await test(source))) { console.error("the finding does not reproduce"); process.exit(2); }
    const small = await reduce(source, test, (m) => console.error(m));
    const out = arg("--out", file.replace(/\.lus$/, ".min.lus"));
    writeFileSync(out, small);
    console.error("wrote " + out);
    process.stdout.write(small);
}
