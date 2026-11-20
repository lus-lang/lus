// csv: generate CSV text, parse it with a hand-written RFC 4180 parser,
// and aggregate per region.
"use strict";

const N = process.argv[2] ? parseInt(process.argv[2], 10) : 2000000;

let state = 42;
function rand(n) {
  state = (state * 48271) % 2147483647;
  return state % n;
}

const REGIONS = ["north", "south", "east", "west", "central", "coastal", "mountain", "island"];
const WORDS = ["fragile", "gift", "urgent", "bulk", "sample"];

function generate(n) {
  const parts = ["id,region,product,quantity,price_cents,note\n"];
  for (let id = 1; id <= n; id++) {
    const region = REGIONS[rand(8)];
    const product = rand(200);
    const quantity = rand(20) + 1;
    const price = rand(100000);
    const k = rand(10);
    let note;
    if (k === 0) note = '"big, ""rush"" order"';
    else if (k < 4) note = "";
    else note = WORDS[rand(5)];
    parts.push(`${id},${region},p${product},${quantity},${price},${note}\n`);
  }
  return parts.join("");
}

// RFC 4180 parser: returns an array of rows, each an array of string fields.
function parse(s) {
  const rows = [];
  let row = [];
  let pos = 0;
  const len = s.length;
  while (pos < len) {
    let field, next;
    if (s.charCodeAt(pos) === 34) {
      let i = pos + 1;
      let hasQuote = false;
      for (;;) {
        const q = s.indexOf('"', i);
        if (q < 0) throw new Error("unterminated quoted field");
        if (s.charCodeAt(q + 1) === 34) {
          hasQuote = true;
          i = q + 2;
        } else {
          field = s.slice(pos + 1, q);
          next = q + 1;
          break;
        }
      }
      if (hasQuote) field = field.replaceAll('""', '"');
    } else {
      let d = pos;
      while (d < len) {
        const c = s.charCodeAt(d);
        if (c === 44 || c === 10) break;
        d++;
      }
      field = s.slice(pos, d);
      next = d;
    }
    row.push(field);
    if (s.charCodeAt(next) === 44) {
      pos = next + 1;
      if (pos >= len) row.push("");
    } else {
      rows.push(row);
      row = [];
      pos = next + 1;
    }
  }
  return rows;
}

const rows = parse(generate(N));
const stats = new Map();
for (const r of REGIONS) stats.set(r, [0, 0, 0, 0]);
let commas = 0;
for (let i = 1; i < rows.length; i++) {
  const r = rows[i];
  const st = stats.get(r[1]);
  const q = parseInt(r[3], 10);
  const p = parseInt(r[4], 10);
  st[0] += 1;
  st[1] += q;
  st[2] += q * p;
  if (p > st[3]) st[3] = p;
  if (r[5].includes(",")) commas++;
}
const out = ["csv"];
for (const name of REGIONS) {
  const st = stats.get(name);
  out.push(`${st[0]} ${st[1]} ${st[2] % 1000000007} ${st[3]}`);
}
out.push(String(commas));
console.log(out.join(" "));
