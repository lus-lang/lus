import assert from "node:assert/strict"
import test from "node:test"

import { columnOrder, scores, type BenchData } from "../src/lib/bench-order.ts"

const data: BenchData = {
  runtimes: { lus: { name: "Lus" }, a: { name: "A" }, b: { name: "B" }, c: { name: "C" } },
  programs: {
    one: {
      lus: { best_s: 2, peak_rss_mb: 10 },
      a: { best_s: 1, peak_rss_mb: 40 },
      b: { best_s: 4, peak_rss_mb: 20 },
      c: { ok: false },
    },
    two: {
      lus: { best_s: 2, peak_rss_mb: 10 },
      a: { best_s: 1, peak_rss_mb: 10 },
      b: { best_s: 16, peak_rss_mb: 20 },
    },
  },
}

test("scores are geometric means of cost relative to the best", () => {
  const s = scores(data, "best_s")
  assert.equal(s.get("a"), 1)
  assert.equal(s.get("lus"), 2)
  // b: 4 then 16, so the mean of 4 and 16 in the log domain is 8
  assert.equal(s.get("b")!.toFixed(6), (8).toFixed(6))
  // a runtime with no result scores last
  assert.equal(s.get("c"), Infinity)
})

test("Lus leads and the others follow from best to worst, per metric", () => {
  assert.deepEqual(columnOrder(data, "best_s"), ["lus", "a", "b", "c"])
  // memory: a scores 2 (4 then 1), b scores 2 (2 then 2), so names break the tie
  assert.deepEqual(columnOrder(data, "peak_rss_mb"), ["lus", "a", "b", "c"])
})

test("each metric has its own order", () => {
  const flipped = structuredClone(data)
  flipped.programs.two.a = { best_s: 1, peak_rss_mb: 80 }
  assert.deepEqual(columnOrder(flipped, "best_s"), ["lus", "a", "b", "c"])
  assert.deepEqual(columnOrder(flipped, "peak_rss_mb"), ["lus", "b", "a", "c"])
})
