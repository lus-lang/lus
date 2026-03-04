// @ts-check
import { defineConfig } from "astro/config"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"

import tailwindcss from "@tailwindcss/vite"

import mdx from "@astrojs/mdx"

import sitemap from "@astrojs/sitemap"

import lusGrammar from "../lus-textmate/lus.tmLanguage.json"

/** @returns {import("vite").Plugin} */
function lucideIconData() {
  const iconsDir = join(process.cwd(), "node_modules/@lucide/astro/src/icons")
  const manualDir = join(process.cwd(), "src/manual")
  return {
    name: "vite-plugin-lucide-icon-data",
    resolveId(id) {
      if (id === "virtual:lucide-icons") return "\0virtual:lucide-icons"
    },
    load(id) {
      if (id !== "\0virtual:lucide-icons") return
      const needed = new Set(["library"])
      for (const file of readdirSync(manualDir).filter((f) => f.endsWith(".mdx"))) {
        const match = readFileSync(join(manualDir, file), "utf-8").match(/^icon:\s*(.+)$/m)
        if (match) needed.add(match[1].trim())
      }
      const entries = []
      for (const name of needed) {
        const source = readFileSync(join(iconsDir, `${name}.ts`), "utf-8")
        const match = source.match(/createLucideIcon\(\s*'[^']+',\s*(\[.+?\])\s*\)/)
        if (match) entries.push(`"${name}":${match[1]}`)
      }
      return `export default{${entries.join(",")}}`
    },
  }
}

// https://astro.build/config
export default defineConfig({
  output: "static",
  redirects: {
    "/manual/tldr": "/manual/acquis",
  },
  site: "https://lus.dev",
  vite: {
    plugins: [tailwindcss(), lucideIconData()],
    server: {
      headers: {
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
      },
    },
  },
  markdown: {
    shikiConfig: {
      themes: {
        light: "github-light",
        dark: "github-light",
      },
      langs: [
        // @ts-ignore
        {
          ...lusGrammar,
          aliases: ["lua"],
        },
      ],
    },
  },
  integrations: [mdx(), sitemap()],
})
