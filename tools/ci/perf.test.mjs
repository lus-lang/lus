// Tests of the comparison of benchmark measurements. Run: mise run ci:test

import assert from "node:assert/strict";
import {test} from "node:test";
import {benches, compare, mad, median, table} from "./perf.mjs";

const m = (time, timeMad, rss, rssMad = 0) => ({time: {median: time, mad: timeMad}, rss: {median: rss, mad: rssMad}});
const config = {mads: 3, thresholds: {time: {ratio: 0.07, floor: 0.005}, rss: {ratio: 0.05, floor: 262144}}};

test("median and deviation", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 2, 3]), 2.5);
  assert.equal(mad([1, 2, 3, 4, 100]), 1);
});

test("a regression needs both the ratio and the noise", () => {
  const base = {benches: {"a.lus": m(1.0, 0.01, 10e6), "b.lus": m(1.0, 0.2, 10e6), "c.lus": m(0.01, 0.0001, 10e6)}};
  const cur = {benches: {"a.lus": m(1.1, 0.01, 10e6), "b.lus": m(1.1, 0.2, 12e6), "c.lus": m(0.012, 0.0001, 10e6)}};
  const r = compare(cur, base, config);
  assert.deepEqual(r.regressions.map((x) => `${x.bench}:${x.key}`), ["a.lus:time", "b.lus:rss"]);
  assert.match(table(r, "x"), /2 regressions/);
});

test("every benchmark file is listed", () => {
  assert.ok(benches().includes("fib.lus"));
  assert.deepEqual(benches(["fib.lus", "nothing.lus"]), ["fib.lus"]);
});
