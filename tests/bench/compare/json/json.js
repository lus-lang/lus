// JSON encode and decode round trip over generated records.
"use strict";

const N = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 1000000;

let state = 42;
function rand(n) {
    state = (state * 48271) % 2147483647;
    return state % n;
}

function main() {
    const records = [];
    for (let i = 1; i <= N; i++) {
        const name = "user" + rand(100000);
        const age = rand(90);
        const active = rand(2) === 1;
        const t1 = "t" + rand(50);
        const t2 = "t" + rand(50);
        const score = rand(1000000);
        records.push({ id: i, name, age, active, tags: [t1, t2], score });
    }

    const text = JSON.stringify(records);
    const back = JSON.parse(text);

    let active = 0;
    let agesum = 0;
    let scoresum = 0;
    const seen = new Set();
    for (const r of back) {
        if (r.active) active++;
        agesum += r.age;
        scoresum += r.score;
        for (const tag of r.tags) seen.add(tag);
    }

    console.log(`json ${active} ${agesum} ${scoresum % 1000000007} ${seen.size} ${Buffer.byteLength(text)}`);
}

main();
