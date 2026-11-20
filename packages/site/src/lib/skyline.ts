/*
** Heights for a title skyline: one bar per entry, sized by length on a
** square-root scale from one to five cubes.
*/
export function skyline(lengths: number[]): number[] {
  const top = Math.max(...lengths.map(Math.sqrt))
  return lengths.map((n) => 1 + Math.round((Math.sqrt(n) / top) * 4))
}
