/*
** How Lus stands against each runtime of the benchmark suite, for the
** homepage. Every word of the speed line comes from the data: it names
** the runtimes Lus beats on every program in both time and memory.
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

export interface Standing {
  id: string
  name: string
  /** geometric mean of their time over Lus's time, above 1 when Lus is faster */
  speedup: number
  /** Lus is faster and uses less memory on every program both ran */
  leads: boolean
}

function value(cell: BenchCell | undefined, key: "best_s" | "peak_rss_mb"): number | null {
  if (!cell || cell.ok === false) return null
  const v = cell[key]
  return typeof v === "number" && v > 0 ? v : null
}

export function standings(data: BenchData): Standing[] {
  return Object.keys(data.runtimes)
    .filter((id) => id !== "lus")
    .map((id) => {
      const logs: number[] = []
      let leads = true
      for (const cells of Object.values(data.programs)) {
        const ours = value(cells.lus, "best_s")
        const theirs = value(cells[id], "best_s")
        if (ours === null || theirs === null) continue
        logs.push(Math.log(theirs / ours))
        const ourMem = value(cells.lus, "peak_rss_mb")
        const theirMem = value(cells[id], "peak_rss_mb")
        if (theirs <= ours || (ourMem !== null && theirMem !== null && theirMem <= ourMem)) leads = false
      }
      const speedup = logs.length ? Math.exp(logs.reduce((a, b) => a + b, 0) / logs.length) : 1
      return { id, name: data.runtimes[id].name, speedup, leads: leads && logs.length > 0 }
    })
    .toSorted((a, b) => b.speedup - a.speedup)
}

const WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

/** Small counts as words, as prose spells them. */
export function countText(n: number): string {
  return WORDS[n] ?? String(n)
}

export function listText(items: string[]): string {
  if (items.length <= 2) return items.join(" and ")
  return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`
}

/** The sentence under the speed heading. */
export function leadLine(data: BenchData): string {
  const all = standings(data)
  const led = all.filter((s) => s.leads).map((s) => s.name)
  const programs = countText(Object.keys(data.programs).length)
  if (led.length === all.length && led.length > 0) {
    return `On ${programs} everyday programs Lus runs faster and in less memory than every other runtime measured.`
  }
  if (led.length > 0) {
    return `On ${programs} everyday programs Lus runs faster and in less memory than ${listText(led)}.`
  }
  return `Measured on ${programs} everyday programs against ${listText(all.map((s) => s.name))}.`
}
