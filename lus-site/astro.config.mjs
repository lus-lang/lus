// @ts-check
import { defineConfig } from "astro/config"
import { rehypeHeadingIds } from "@astrojs/markdown-remark"
import rehypeAutolinkHeadings from "rehype-autolink-headings"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"

import tailwindcss from "@tailwindcss/vite"

import mdx from "@astrojs/mdx"

import sitemap from "@astrojs/sitemap"

import lusGrammar from "../lus-textmate/lus.tmLanguage.json"

/**
 * Wrap every table in a focusable horizontal-scroll container so wide
 * tables don't overflow small viewports.
 * @returns {(tree: any) => void}
 */
function rehypeTableWrap() {
  /** @param {any} node */
  const walk = (node) => {
    if (!node.children) return
    node.children = node.children.map((/** @type {any} */ child) => {
      if (child.type === "element" && child.tagName === "table") {
        return {
          type: "element",
          tagName: "div",
          properties: {
            className: ["table-wrap"],
            tabIndex: 0,
            role: "region",
            "aria-label": "table",
          },
          children: [child],
        }
      }
      walk(child)
      return child
    })
  }
  return walk
}

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
      const needed = new Set([
        // Manual sidebar (API + C API)
        "library", "braces",
        // Nav icons
        "terminal", "book-open", "newspaper", "code-xml",
        // Landing
        "arrow-right", "download",
      ])
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
    // deleted pages — the faq's load-bearing answers migrated into the
    // manual; the only surviving search is the API filter
    "/faq": "/manual/introduction",
    "/search": "/manual/api",
  },
  site: "https://lus.dev",
  vite: {
    plugins: [tailwindcss(), lucideIconData()],
    server: {
      headers: {
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
      },
      fs: {
        // install.sh.ts raw-imports lus-install/install.sh from the
        // repo root, one level above the site project
        allow: [".."],
      },
    },
  },
  markdown: {
    rehypePlugins: [
      rehypeHeadingIds,
      [
        rehypeAutolinkHeadings,
        {
          behavior: "append",
          properties: {
            className: ["heading-anchor"],
            ariaLabel: "Link to this section",
          },
          content: { type: "text", value: "#" },
        },
      ],
      rehypeTableWrap,
    ],
    shikiConfig: {
      theme: "github-light",
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
