/*
** Single source of truth for the API reference: section ordering, entry
** provenance (`from`), and the grouped views the index and the entry
** renderer both consume. The index page is generated from this, so never
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
  page?: { href: string; title: string }
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
  /** The manual page that explains the library, when one exists. */
  page?: { href: string; title: string }
  filter: (d: ApiData, id: string) => boolean
}

const stdlibOrder: SectionSpec[] = [
  { title: "Environment functions", filter: (d) => d.module === "base" },
  { title: "Table library", page: { href: "/manual/data#table-functions", title: "Table functions" }, filter: (d) => d.module === "table" },
  { title: "String library", page: { href: "/manual/text#strings", title: "Strings" }, filter: (d) => d.module === "string" },
  { title: "Math library", filter: (d) => d.module === "math" },
  { title: "IO library", filter: (d) => d.module === "io" },
  { title: "OS library", filter: (d) => d.module === "os" },
  { title: "Debug library", page: { href: "/manual/tools#debugger", title: "Debugger" }, filter: (d) => d.module === "debug" },
  { title: "Coroutine library", page: { href: "/manual/concurrency#detached-coroutines", title: "Detached coroutines" }, filter: (d) => d.module === "coroutine" },
  { title: "Package library", page: { href: "/manual/guide#modules", title: "Modules and require" }, filter: (d) => d.module === "package" },
  { title: "UTF-8 library", filter: (d) => d.module === "utf8" },
  {
    title: "Filesystem library", page: { href: "/manual/filesystem", title: "Filesystem" },
    filter: (d) => d.module === "fs" || d.module === "fs.path",
  },
  {
    title: "Network library", page: { href: "/manual/network", title: "Network" },
    filter: (d) =>
      d.module === "network" ||
      d.module === "network.tcp" ||
      d.module === "network.udp",
  },
  { title: "Vector library", page: { href: "/manual/text#vectors", title: "Vectors" }, filter: (d) => d.module === "vector" },
  {
    title: "Archive library", page: { href: "/manual/text#compression", title: "Compression" },
    filter: (d) => !!d.module?.startsWith("vector.archive"),
  },
  {
    title: "Worker library", page: { href: "/manual/concurrency#workers", title: "Workers" },
    filter: (d) => d.module === "worker" && !d.header,
  },
  { title: "Time library", page: { href: "/manual/time", title: "Time" }, filter: (d) => d.module === "time" },
  { title: "Crypto library", page: { href: "/manual/crypto", title: "Cryptography" }, filter: (d) => d.module === "crypto" },
]

/* C API entries are grouped by their directory under spec/capi. */
const capiGroup =
  (dir: string) =>
  (_d: ApiData, id: string): boolean =>
    id.startsWith(`${dir}/`)

const capiOrder: SectionSpec[] = [
  { title: "State", filter: capiGroup("state") },
  { title: "Stack", filter: capiGroup("stack") },
  { title: "Reading Values", filter: capiGroup("read") },
  { title: "Pushing Values", filter: capiGroup("push") },
  { title: "Tables and Globals", filter: capiGroup("tables") },
  { title: "C Functions", filter: capiGroup("functions") },
  { title: "Userdata and Metatables", filter: capiGroup("userdata") },
  { title: "References", filter: capiGroup("references") },
  { title: "Loading and Calling", filter: capiGroup("call") },
  { title: "Errors", filter: capiGroup("errors") },
  { title: "Permissions", filter: capiGroup("permissions") },
]

function sectionize(entries: ApiEntry[], order: SectionSpec[]): ApiSection[] {
  const sorted = entries.toSorted((a, b) =>
    a.data.name.localeCompare(b.data.name),
  )
  const used = new Set<string>()
  const sections: ApiSection[] = []
  for (const spec of order) {
    const matched = sorted.filter(
      (e) => !used.has(e.data.name) && spec.filter(e.data, e.id),
    )
    for (const e of matched) used.add(e.data.name)
    if (matched.length > 0) {
      sections.push({
        title: spec.title,
        id: slug(spec.title),
        page: spec.page,
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

/** The first sentence of an entry body as plain text, for summaries. */
export function summary(entry: ApiEntry): string {
  const para = (entry.body ?? "").trim().split(/\n\s*\n/)[0] ?? ""
  if (para.startsWith("```")) return ""
  const text = para
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[`*_]/g, "")
    .replace(/\s+/g, " ")
    .trim()
  const end = text.search(/[.!?](\s|$)/)
  return end >= 0 ? text.slice(0, end + 1) : text
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
