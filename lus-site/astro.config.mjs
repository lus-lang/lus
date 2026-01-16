// @ts-check
import { defineConfig } from "astro/config"

import tailwindcss from "@tailwindcss/vite"

import mdx from "@astrojs/mdx"

import sitemap from "@astrojs/sitemap"

import lusGrammar from "../lus-textmate/lus.tmLanguage.json"

// https://astro.build/config
export default defineConfig({
  output: "static",
  site: "https://lus.dev",
  vite: {
    plugins: [tailwindcss()],
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
