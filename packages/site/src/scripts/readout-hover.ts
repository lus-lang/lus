/*
** Pointing at an entry in a page's list, or moving keyboard focus to it,
** lights its bar in the title readout. Entries carry data-bar with the
** bar's column, and the readout bars carry data-j. The change is a
** repaint, removed when the pointer or focus moves on.
*/

let lit: Element[] = []

function paint(col: string | null) {
  for (const el of lit) el.classList.remove("hl")
  lit = []
  if (col === null) return
  lit = [...document.querySelectorAll(`.title-row svg g[data-j="${col}"]`)]
  for (const el of lit) el.classList.add("hl")
}

document.addEventListener("pointerover", (ev) => {
  const entry = (ev.target as Element).closest<HTMLElement>("[data-bar]")
  paint(entry ? entry.dataset.bar! : null)
})

document.addEventListener("focusin", (ev) => {
  const entry = (ev.target as Element).closest<HTMLElement>("[data-bar]")
  paint(entry ? entry.dataset.bar! : null)
})
