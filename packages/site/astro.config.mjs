// @ts-check
import { defineConfig } from "astro/config"
import { rehypeHeadingIds, unified } from "@astrojs/markdown-remark"
import rehypeAutolinkHeadings from "rehype-autolink-headings"

import tailwindcss from "@tailwindcss/vite"

import mdx from "@astrojs/mdx"

import sitemap from "@astrojs/sitemap"

import lusGrammar from "../textmate/lus.tmLanguage.json"
import codeTheme from "./src/lib/code-theme.mjs"

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

// https://astro.build/config
export default defineConfig({
  output: "static",
  publicDir: process.env.LUS_SITE_PUBLIC_DIR || "./public",
  redirects: {
    "/manual/tldr": "/manual/acquis",
    // deleted pages; the faq's load-bearing answers migrated into the
    // manual; the only surviving search is the API filter
    "/faq": "/manual/introduction",
    "/search": "/manual/api",
  },
  site: "https://lus.dev",
  vite: {
    plugins: [tailwindcss()],
    server: {
      fs: {
        // the site imports from the repo root (examples, spec, packaging),
        // two levels above the site project
        allow: ["../.."],
      },
    },
  },
  markdown: {
    processor: unified({
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
    }),
    shikiConfig: {
      // @ts-ignore
      theme: codeTheme,
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
