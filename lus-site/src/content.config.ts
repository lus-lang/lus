import { defineCollection, z } from "astro:content"
import { glob } from "astro/loaders"

const news = defineCollection({
  schema: z.object({
    title: z.string(),
    date: z.string(),
  }),
  loader: glob({ base: "./src/news/", pattern: "*.md" }),
})

const manual = defineCollection({
  schema: z.object({
    title: z.string(),
    order: z.number(),
    acquis: z.boolean().optional(),
    draft: z.boolean().optional(),
    icon: z.string().optional(),
    shortdesc: z.string().optional(),
  }),
  loader: glob({ base: "./src/manual/", pattern: "*.mdx" }),
})

const paramSchema = z.object({
  name: z.string(),
  type: z.string().optional(),
  optional: z.boolean().optional(),
})

const returnSchema = z.object({
  type: z.string(),
  name: z.string().optional(),
})

const specSchema = z.object({
  name: z.string(),
  module: z.string().optional(),
  header: z.string().optional(),
  kind: z.enum(["function", "constant", "variable", "module", "type", "macro"]),
  since: z.string(),
  stability: z.enum(["stable", "unstable", "deprecated", "removed"]),
  origin: z.enum(["lua", "lus"]),
  params: z.array(paramSchema).optional(),
  vararg: z.boolean().optional(),
  returns: z.union([z.string(), z.array(returnSchema)]).optional(),
  type: z.string().optional(),
  value: z.union([z.string(), z.number()]).optional(),
  signature: z.string().optional(),
  deprecated_by: z.string().optional(),
  removed_in: z.string().optional(),
  fastcall: z.boolean().optional(),
})

const stdlib = defineCollection({
  schema: specSchema,
  loader: glob({ base: "../lus-spec/stdlib/", pattern: "**/*.md" }),
})

const capi = defineCollection({
  schema: specSchema,
  loader: glob({ base: "../lus-spec/capi/", pattern: "**/*.md" }),
})

export const collections = { news, manual, stdlib, capi }
