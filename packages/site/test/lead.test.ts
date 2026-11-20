import assert from "node:assert/strict"
import test from "node:test"

import { leadLine, listText, standings, type BenchData } from "../src/lib/lead.ts"

const data: BenchData = {
  runtimes: { lus: { name: "Lus" }, node: { name: "Node.js" }, py: { name: "Python" } },
  programs: {
    a: {
      lus: { best_s: 1, peak_rss_mb: 10 },
      node: { best_s: 2, peak_rss_mb: 20 },
      py: { best_s: 0.5, peak_rss_mb: 5 },
    },
    b: {
      lus: { best_s: 1, peak_rss_mb: 10 },
      node: { best_s: 8, peak_rss_mb: 30 },
      py: { best_s: 4, peak_rss_mb: 40 },
    },
  },
}

test("speedups are geometric means and name the runtime", () => {
  const s = standings(data)
  assert.deepEqual(s.map((x) => x.name), ["Node.js", "Python"])
  assert.equal(s[0].speedup.toFixed(3), "4.000")
  assert.equal(s[1].speedup.toFixed(3), "1.414")
  assert.equal(s[0].leads, true)
  assert.equal(s[1].leads, false)
})

test("the line names only the runtimes Lus leads everywhere", () => {
  assert.equal(leadLine(data), "On two everyday programs Lus runs faster and in less memory than Node.js.")
  const all = structuredClone(data)
  all.programs.a.py = { best_s: 3, peak_rss_mb: 50 }
  assert.equal(leadLine(all), "On two everyday programs Lus runs faster and in less memory than every other runtime measured.")
  const none = structuredClone(data)
  none.programs.a.node = { best_s: 0.1, peak_rss_mb: 1 }
  none.programs.a.py = { best_s: 0.1, peak_rss_mb: 1 }
  assert.equal(leadLine(none), "Measured on two everyday programs against Node.js and Python.")
})

test("lists read as prose", () => {
  assert.equal(listText(["a"]), "a")
  assert.equal(listText(["a", "b"]), "a and b")
  assert.equal(listText(["a", "b", "c"]), "a, b, and c")
})
