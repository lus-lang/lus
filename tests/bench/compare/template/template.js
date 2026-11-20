// template: render an HTML report for generated items with escaping,
// built with an array and join.
"use strict";

const N = process.argv[2] ? parseInt(process.argv[2], 10) : 1000000;

let state = 42;
function rand(n) {
  state = (state * 48271) % 2147483647;
  return state % n;
}

const TAGS = ["new", "sale", "<hot>", "a&b", '"quoted"', "it's", "x>y", "plain"];

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
function escape(s) {
  return s.replace(/[&<>"']/g, (c) => ESC[c]);
}

const items = [];
for (let id = 1; id <= N; id++) {
  const title = `Item ${id} & ${rand(1000)} ${TAGS[rand(8)]}`;
  const price = rand(100000);
  const tags = [];
  const count = rand(3) + 1;
  for (let j = 0; j < count; j++) tags.push(TAGS[rand(8)]);
  items.push({ id, title, price, tags });
}

function render(list) {
  const out = [
    "<!DOCTYPE html>\n<html><head><title>Report</title></head><body>\n",
    "<h1>Items &amp; prices</h1>\n<table>\n",
    "<tr><th>ID</th><th>Title</th><th>Price</th><th>Tags</th></tr>\n",
  ];
  for (const item of list) {
    const dollars = Math.floor(item.price / 100);
    const cents = String(item.price % 100).padStart(2, "0");
    const tags = item.tags.map(escape).join(", ");
    out.push(`<tr><td>${item.id}</td><td>${escape(item.title)}</td><td>$${dollars}.${cents}</td><td>${tags}</td></tr>\n`);
  }
  out.push(`</table>\n<p>${list.length} items</p>\n</body></html>\n`);
  return out.join("");
}

const page = render(items);
let sum = 0;
for (let i = 96; i < page.length; i += 97) sum += page.charCodeAt(i);
console.log(`template ${page.length} ${sum % 1000000007}`);
