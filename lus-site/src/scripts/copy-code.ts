/*
** Injects a copy-to-clipboard button into every code block under <main>.
** SVGs are inlined here (not routed through the lucide vite plugin)
** because this runs purely on the client.
*/

const COPY_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect width="14" height="14" x="8" y="8" rx="0" ry="0"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>`
const CHECK_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>`
const FAIL_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>`

function attachCopyButtons() {
  for (const pre of document.querySelectorAll<HTMLPreElement>("main pre")) {
    if (pre.dataset.copyReady) continue
    const code = pre.querySelector("code")
    if (!code) continue
    pre.dataset.copyReady = "true"

    // keyboard focus belongs on the scroll container (the code element);
    // Astro emits tabindex="0" on Shiki pres, which don't scroll anymore
    pre.removeAttribute("tabindex")
    code.tabIndex = 0

    const btn = document.createElement("button")
    btn.className = "copy-btn"
    btn.type = "button"
    btn.setAttribute("aria-label", "Copy code")
    const icon = document.createElement("span")
    icon.innerHTML = COPY_SVG
    const announce = document.createElement("span")
    announce.className = "sr-only"
    announce.setAttribute("aria-live", "polite")
    btn.append(icon, announce)

    // feedback persists while the pointer/focus stays on the button and
    // reverts on the user's way out — no timer-driven repaints
    const restore = () => {
      icon.innerHTML = COPY_SVG
      announce.textContent = ""
      btn.classList.remove("copied")
      btn.setAttribute("aria-label", "Copy code")
    }
    btn.addEventListener("pointerleave", restore)
    btn.addEventListener("blur", restore)

    btn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.innerText)
        icon.innerHTML = CHECK_SVG
        btn.classList.add("copied")
        btn.setAttribute("aria-label", "Copied")
        announce.textContent = "Copied"
      } catch {
        /* clipboard unavailable (permissions/insecure context) */
        icon.innerHTML = FAIL_SVG
        btn.setAttribute("aria-label", "Copy failed")
        announce.textContent = "Copy failed"
      }
    })

    pre.appendChild(btn)
  }
}

attachCopyButtons()
