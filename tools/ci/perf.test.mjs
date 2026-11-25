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
  // Ids outside the perf map take the default ratios of the config.
  const base = {benches: {a: m(1.0, 0.01, 10e6), b: m(1.0, 0.2, 10e6), c: m(0.01, 0.0001, 10e6)}};
  const cur = {benches: {a: m(1.1, 0.01, 10e6), b: m(1.1, 0.2, 12e6), c: m(0.012, 0.0001, 10e6)}};
  const r = compare(cur, base, config);
  assert.deepEqual(r.regressions.map((x) => `${x.bench}:${x.key}`), ["a:time", "b:rss"]);
  assert.match(table(r, "x"), /2 regressions/);
});

test("the benchmarks are the ids of the perf map", () => {
  assert.ok(benches().includes("fib"));
  assert.ok(benches().includes("compare/json"));
  assert.deepEqual(benches(["fib", "nothing"]), ["fib"]);
});

test("each benchmark has its own threshold", () => {
  const base = {benches: {gcpause: m(1.0, 0.0, 100e6), fib: m(1.0, 0.0, 10e6)}};
  // gcpause allows 19% more memory, and fib allows 2%, so 10% more fails only fib.
  const cur = {benches: {gcpause: m(1.0, 0.0, 110e6), fib: m(1.0, 0.0, 11e6)}};
  const r = compare(cur, base, config);
  assert.deepEqual(r.regressions.map((x) => `${x.bench}:${x.key}`), ["fib:rss"]);
});
