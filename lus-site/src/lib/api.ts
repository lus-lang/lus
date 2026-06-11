/*
** Single source of truth for the API reference: section ordering, entry
** provenance (`from`), and the grouped views the index and the entry
** renderer both consume. The index page is generated from this — never
** hand-maintain API link lists.
*/

import { getCollection, type CollectionEntry } from "astro:content"

export type ApiEntry = CollectionEntry<"stdlib"> | CollectionEntry<"capi">
export type ApiData = ApiEntry["data"]

/** Provenance, in priority order; drives badges and index link colors. */
export type From = "removed" | "deprecated" | "lus-unstable" | "lus" | "lua"

export interface SectionedEntry {
  entry: ApiEntry
  from: From
}

export interface ApiSection {
  title: string
  id: string
  entries: SectionedEntry[]
}

export function entryFrom(d: ApiData): From {
  if (d.stability === "removed") return "removed"
  if (d.stability === "deprecated") return "deprecated"
  if (d.origin === "lus") {
    return d.stability === "unstable" ? "lus-unstable" : "lus"
  }
  return "lua"
}

function slug(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
}

interface SectionSpec {
  title: string
  filter: (d: ApiData) => boolean
}

const stdlibOrder: SectionSpec[] = [
  { title: "Environment Functions", filter: (d) => d.module === "base" },
  { title: "Table Library", filter: (d) => d.module === "table" },
  { title: "String Library", filter: (d) => d.module === "string" },
  { title: "Math Library", filter: (d) => d.module === "math" },
  { title: "IO Library", filter: (d) => d.module === "io" },
  { title: "OS Library", filter: (d) => d.module === "os" },
  { title: "Debug Library", filter: (d) => d.module === "debug" },
  { title: "Coroutine Library", filter: (d) => d.module === "coroutine" },
  { title: "Package Library", filter: (d) => d.module === "package" },
  { title: "UTF-8 Library", filter: (d) => d.module === "utf8" },
  {
    title: "Filesystem Library",
    filter: (d) => d.module === "fs" || d.module === "fs.path",
  },
  {
    title: "Network Library",
    filter: (d) =>
      d.module === "network" ||
      d.module === "network.tcp" ||
      d.module === "network.udp",
  },
  { title: "Vector Library", filter: (d) => d.module === "vector" },
  {
    title: "Archive Library",
    filter: (d) => !!d.module?.startsWith("vector.archive"),
  },
  {
    title: "Worker Library",
    filter: (d) => d.module === "worker" && !d.header,
  },
]

const capiOrder: SectionSpec[] = [
  {
    title: "Permission System — C API",
    filter: (d) => d.header === "lpledge.h",
  },
  {
    title: "Worker System — C API",
    filter: (d) => d.header === "lworkerlib.h",
  },
  { title: "Library Openers", filter: (d) => d.header === "lualib.h" },
  { title: "Core C API", filter: (d) => d.header === "lua.h" },
  { title: "Auxiliary C API", filter: (d) => d.header === "lauxlib.h" },
]

function sectionize(entries: ApiEntry[], order: SectionSpec[]): ApiSection[] {
  const sorted = entries.toSorted((a, b) =>
    a.data.name.localeCompare(b.data.name),
  )
  const used = new Set<string>()
  const sections: ApiSection[] = []
  for (const spec of order) {
    const matched = sorted.filter(
      (e) => !used.has(e.data.name) && spec.filter(e.data),
    )
    for (const e of matched) used.add(e.data.name)
    if (matched.length > 0) {
      sections.push({
        title: spec.title,
        id: slug(spec.title),
        entries: matched.map((entry) => ({ entry, from: entryFrom(entry.data) })),
      })
    }
  }
  const remaining = sorted.filter((e) => !used.has(e.data.name))
  if (remaining.length > 0) {
    sections.push({
      title: "Other",
      id: "other",
      entries: remaining.map((entry) => ({ entry, from: entryFrom(entry.data) })),
    })
  }
  return sections
}

export async function getStdlibSections(): Promise<ApiSection[]> {
  return sectionize(await getCollection("stdlib"), stdlibOrder)
}

export async function getCapiSections(): Promise<ApiSection[]> {
  return sectionize(await getCollection("capi"), capiOrder)
}

/** Order in which kinds are grouped inside an index section. */
export const kindOrder = [
  "type",
  "macro",
  "function",
  "variable",
  "constant",
  "module",
] as const

export function groupByKind(
  entries: SectionedEntry[],
): { kind: string; entries: SectionedEntry[] }[] {
  return kindOrder
    .map((kind) => ({
      kind,
      entries: entries.filter(({ entry }) => entry.data.kind === kind),
    }))
    .filter((g) => g.entries.length > 0)
}
