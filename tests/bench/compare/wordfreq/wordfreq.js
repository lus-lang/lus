// wordfreq: count word frequencies in a generated text.
const n = process.argv[2] ? parseInt(process.argv[2], 10) : 10000000;

let state = 42;
function rand(m) {
  state = (state * 48271) % 2147483647;
  return state % m;
}

const letters = "abcdefghijklmnopqrstuvwxyz";
const vocab = [];
for (let k = 0; k < 5000; k++) {
  const len = 3 + rand(7);
  let word = "";
  for (let j = 0; j < len; j++) {
    let ch = letters[rand(26)];
    if (rand(5) === 0) ch = ch.toUpperCase();
    word += ch;
  }
  vocab.push(word);
}

const punct = [",", ".", "!"];
const parts = [];
for (let i = 1; i <= n; i++) {
  parts.push(vocab[rand(rand(5000) + 1)]);
  if (rand(12) === 0) parts.push(punct[rand(3)]);
  parts.push(i % 12 === 0 ? "\n" : " ");
}
const text = parts.join("");
parts.length = 0;

const counts = new Map();
let total = 0;
for (const m of text.matchAll(/[A-Za-z]+/g)) {
  const w = m[0].toLowerCase();
  counts.set(w, (counts.get(w) || 0) + 1);
  total++;
}

const ranked = [...counts.entries()].sort((a, b) =>
  b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));

const out = ["wordfreq", ranked.length, total];
for (let i = 0; i < 10; i++) out.push(ranked[i][1]);
for (let i = 0; i < 3; i++) out.push(ranked[i][0]);
console.log(out.join(" "));
