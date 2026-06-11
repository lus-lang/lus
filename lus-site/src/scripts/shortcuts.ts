/*
** `/` focuses the API filter (#api-search). Loaded by ApiReference, so
** the listener only exists on pages that have the filter.
*/

document.addEventListener("keydown", (ev) => {
  if (ev.key !== "/") return
  const active = document.activeElement
  if (
    active instanceof HTMLInputElement ||
    active instanceof HTMLTextAreaElement ||
    (active instanceof HTMLElement && active.isContentEditable)
  )
    return
  const input = document.querySelector<HTMLInputElement>("#api-search")
  if (!input) return
  ev.preventDefault()
  input.focus()
})
