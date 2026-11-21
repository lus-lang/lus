// @ts-check
import { defineConfig } from "astro/config"
import { rehypeHeadingIds, unified } from "@astrojs/markdown-remark"
import rehypeAutolinkHeadings from "rehype-autolink-headings"

import tailwindcss from "@tailwindcss/vite"

import mdx from "@astrojs/mdx"

import sitemap from "@astrojs/sitemap"

import lusGrammar from "../textmate/lus.tmLanguage.json"
import codeThemes from "./src/lib/code-themes.mjs"

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
    "/manual/tldr": "/manual/guide",
    // the numbered feature pages folded into the guide and the topic pages
    "/manual/acquis": "/manual/guide",
    "/manual/acquis-0": "/manual/introduction",
    "/manual/adapting": "/manual/lua",
    "/manual/patterns": "/manual/lua",
    "/manual/acquis-1": "/manual/guide#errors",
    "/manual/acquis-2": "/manual/guide#optional-chaining",
    "/manual/acquis-3": "/manual/guide#if-statements",
    "/manual/acquis-4": "/manual/guide#destructuring-with-from",
    "/manual/acquis-5": "/manual/guide#enums",
    "/manual/acquis-6": "/manual/data#json",
    "/manual/acquis-7": "/manual/filesystem",
    "/manual/acquis-8": "/manual/text#transcoding",
    "/manual/acquis-9": "/manual/network",
    "/manual/acquis-10": "/manual/permissions",
    "/manual/acquis-11": "/manual/concurrency#workers",
    "/manual/acquis-12": "/manual/tools#syntax-trees",
    "/manual/acquis-13": "/manual/guide#while-loops",
    "/manual/acquis-14": "/manual/tools#lua-idioms-with-a-lus-form",
    "/manual/acquis-15": "/manual/text#vectors",
    "/manual/acquis-16": "/manual/guide#slices",
    "/manual/acquis-17": "/manual/guide#copying-tables",
    "/manual/acquis-18": "/manual/guide#local-groups",
    "/manual/acquis-19": "/manual/tools#standalone-executables",
    "/manual/acquis-20": "/manual/guide#catch-handlers",
    "/manual/acquis-21": "/manual/guide#strings",
    "/manual/acquis-22": "/manual/guide#variable-attributes",
    "/manual/acquis-23": "/manual/guide#do-expressions",
    "/manual/acquis-24": "/manual/data#csv",
    "/manual/acquis-25": "/manual/data#table-functions",
    "/manual/acquis-26": "/manual/text#compression",
    "/manual/acquis-27": "/manual/guide#the---readonly-env-option",
    "/manual/acquis-28": "/manual/guide#build-flags",
    "/manual/acquis-29": "/manual/guide#preincluded-modules",
    "/manual/acquis-30": "/manual/time",
    "/manual/acquis-33": "/manual/sqlite",
    "/manual/acquis-34": "/manual/guide#queries",
    "/manual/acquis-35": "/manual/guide#break-and-continue",
    "/manual/acquis-36": "/manual/guide#numbers",
    "/manual/acquis-37": "/manual/text",
    "/manual/acquis-38": "/manual/testing",
    "/manual/acquis-39": "/manual/tools",
    "/manual/acquis-40": "/manual/tools#debugger",
    "/manual/acquis-41": "/manual/embedding",
    "/manual/acquis-42": "/manual/webassembly",
    "/manual/acquis-43": "/manual/concurrency#detached-coroutines",
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
      themes: codeThemes,
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
