/** ISO date (YYYY-MM-DD) — unambiguous, and suits the mono aesthetic. */
export function fmtDate(date: Date): string {
  return date.toISOString().slice(0, 10)
}
