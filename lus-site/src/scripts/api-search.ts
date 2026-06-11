/*
** Client-side filter for the API reference. Whitespace-separated terms
** are AND-matched as substrings over data-api attributes ("table create"
** finds table.create; "fs unstable" finds unstable fs functions;
** "fastcall" finds VM-intrinsified entries). Hides the curated index and
** the module jump-nav while a query is active so matches are the only
** thing on screen; the legend stays (it explains the result colors).
** The query mirrors into ?q= so filtered views are shareable. Enter
** jumps to the first match. No-ops on pages without #api-search.
*/

function bindApiSearch() {
  const input = document.querySelector<HTMLInputElement>("#api-search")
  if (!input || input.dataset.bound) return
  input.dataset.bound = "true"

  const count = document.querySelector<HTMLElement>("#api-search-count")
  const index = document.querySelector<HTMLElement>(".api-index")
  const modules = document.querySelector<HTMLElement>(".api-modules")
  const entries = Array.from(
    document.querySelectorAll<HTMLElement>(".api-entry[data-api]"),
  )
  const sections = Array.from(
    document.querySelectorAll<HTMLElement>(".api-section"),
  )

  function syncUrl() {
    const url = new URL(location.href)
    const q = input!.value.trim()
    if (q) url.searchParams.set("q", q)
    else url.searchParams.delete("q")
    history.replaceState(null, "", url)
  }

  function apply() {
    const terms = input!.value.trim().toLowerCase().split(/\s+/).filter(Boolean)
    if (terms.length === 0) {
      for (const e of entries) e.hidden = false
      for (const s of sections) s.hidden = false
      if (index) index.hidden = false
      if (modules) modules.hidden = false
      if (count) count.textContent = `${entries.length} entries`
      return
    }
    if (index) index.hidden = true
    if (modules) modules.hidden = true
    let matches = 0
    for (const e of entries) {
      const haystack = e.dataset.api ?? ""
      const hit = terms.every((t) => haystack.includes(t))
      e.hidden = !hit
      if (hit) matches++
    }
    for (const s of sections) {
      s.hidden = !s.querySelector(".api-entry:not([hidden])")
    }
    if (count)
      count.textContent =
        matches === 0
          ? `No matches for "${input!.value.trim()}"`
          : `${matches} match${matches === 1 ? "" : "es"}`
  }

  input.addEventListener("input", () => {
    syncUrl()
    apply()
  })
  input.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && input.value) {
      input.value = ""
      syncUrl()
      apply()
    }
    if (ev.key === "Enter") {
      const first = entries.find((e) => !e.hidden)
      if (first) location.hash = encodeURIComponent(first.id)
    }
  })

  const initial = new URLSearchParams(location.search).get("q")
  if (initial) input.value = initial
  apply()
}

bindApiSearch()
