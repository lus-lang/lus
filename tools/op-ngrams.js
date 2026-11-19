#!/usr/bin/env node
// Ranks the opcode sequences that the interpreter runs over the bench
// corpus, which is how candidates for fused instructions are found.
//
// Usage: node tools/op-ngrams.js <lus built with -Dop-profile=true> [files...]
//
// Each program runs with the JIT off and prints its counts to standard
// error. A sequence scores its share of the instructions of each program,
// averaged over the programs, so that a long benchmark weighs as much as
// a short one. The output lists the best pairs and runs of three with
// their mean share and their largest share in one program.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const [lus, ...given] = process.argv.slice(2);
if (!lus) {
    console.error("usage: node tools/op-ngrams.js <lus built with -Dop-profile=true> [files...]");
    process.exit(2);
}
const bench = path.join(__dirname, "..", "tests", "bench");
const files = given.length > 0
    ? given
    : fs.readdirSync(bench).filter((f) => f.endsWith(".lus")).sort().map((f) => path.join(bench, f));

// sequence -> { sum of shares, largest share, program of the largest share }
const scores = new Map();
let programs = 0;
for (const file of files) {
    const run = spawnSync(lus, [file], {
        env: { ...process.env, LUS_JIT: "off" },
        encoding: "utf8",
        maxBuffer: 1 << 28,
    });
    const counts = [];
    let total = 0;
    for (const line of run.stderr.split("\n")) {
        const m = /^(\d+) ([a-z_0-9]+(?: [a-z_0-9]+){1,2})$/.exec(line);
        if (!m) continue;
        const count = Number(m[1]);
        counts.push([m[2], count]);
        // Every instruction ends exactly one pair.
        if (m[2].split(" ").length === 2) total += count;
    }
    if (total === 0) {
        console.error(`${file}: no counts (is ${lus} built with -Dop-profile=true?)`);
        continue;
    }
    programs += 1;
    const name = path.basename(file, ".lus");
    for (const [seq, count] of counts) {
        const share = count / total;
        const s = scores.get(seq) ?? { sum: 0, max: 0, where: "" };
        s.sum += share;
        if (share > s.max) {
            s.max = share;
            s.where = name;
        }
        scores.set(seq, s);
    }
}

for (const length of [2, 3]) {
    const ranked = [...scores.entries()]
        .filter(([seq]) => seq.split(" ").length === length)
        .sort((a, b) => b[1].sum - a[1].sum)
        .slice(0, 20);
    console.log(`\nsequences of ${length} (mean share of instructions, largest share)`);
    for (const [seq, s] of ranked) {
        const mean = ((100 * s.sum) / programs).toFixed(2).padStart(6);
        const max = (100 * s.max).toFixed(1).padStart(5);
        console.log(`${mean}%  ${max}% in ${s.where.padEnd(9)} ${seq}`);
    }
}
