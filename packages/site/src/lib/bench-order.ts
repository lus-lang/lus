/*
** The order of the runtime columns in the benchmark section, one order
** per metric. A runtime's score is the geometric mean, over the programs
** of the suite, of its result relative to the best result in that
** program: the best runtime of a program scores 1 there, and lower is
** better. Lus comes first and the others follow by score, so the order
** comes from the data and changes when the data does.
*/

export interface BenchCell {
  ok?: boolean
  best_s?: number
  peak_rss_mb?: number
}

export interface BenchData {
  runtimes: Record<string, { name: string }>
  programs: Record<string, Record<string, BenchCell>>
}

/** a metric where lower is better: wall time or peak memory */
export type Metric = "best_s" | "peak_rss_mb"

function value(cell: BenchCell | undefined, key: Metric): number | null {
  if (!cell || cell.ok === false) return null
  const v = cell[key]
  return typeof v === "number" && v > 0 ? v : null
}

/** Each runtime's geometric mean of relative cost, Infinity without results. */
export function scores(data: BenchData, metric: Metric): Map<string, number> {
  const ids = Object.keys(data.runtimes)
  const out = new Map<string, number>()
  for (const id of ids) {
    let logs = 0
    let n = 0
    for (const cells of Object.values(data.programs)) {
      const own = value(cells[id], metric)
      if (own === null) continue
      const best = Math.min(...ids.map((o) => value(cells[o], metric)).filter((v): v is number => v !== null))
      logs += Math.log(own / best)
      n += 1
    }
    out.set(id, n === 0 ? Infinity : Math.exp(logs / n))
  }
  return out
}

/** Lus first, then the other runtimes from best to worst for the metric. */
export function columnOrder(data: BenchData, metric: Metric): string[] {
  const s = scores(data, metric)
  const others = Object.keys(data.runtimes)
    .filter((id) => id !== "lus")
    .toSorted((a, b) => s.get(a)! - s.get(b)! || a.localeCompare(b))
  return ["lus", ...others]
}
