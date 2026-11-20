/*
** The documentation agents read, built once per site build by
** tools/build-llms.js from spec/stdlib, the manual, and .agents/. The
** endpoints under pages/ serve its files: llms.txt and its variants, the
** Markdown twin of every manual page, and the skills.
*/
import { createRequire } from "node:module"
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"

interface Built {
  files: Map<string, string>
}

// the repository root, found from the directory the build runs in
function repoRoot(): string {
  let dir = process.cwd()
  while (!existsSync(join(dir, "tools", "build-llms.js"))) {
    const up = dirname(dir)
    if (up === dir) throw new Error("tools/build-llms.js not found above " + process.cwd())
    dir = up
  }
  return dir
}

let cache: Built | null = null

export function llmsFiles(): Map<string, string> {
  if (!cache) {
    const root = repoRoot()
    const require = createRequire(join(root, "tools", "build-llms.js"))
    const { build, validate } = require("./build-llms.js")
    const built = build(root) as Built
    const problems = validate(built) as string[]
    if (problems.length > 0) throw new Error("agent documentation:\n" + problems.join("\n"))
    cache = built
  }
  return cache.files
}

export function llmsFile(name: string): string {
  const text = llmsFiles().get(name)
  if (text === undefined) throw new Error(`no agent documentation file ${name}`)
  return text
}

export const MARKDOWN = { "Content-Type": "text/markdown; charset=utf-8" }
export const TEXT = { "Content-Type": "text/plain; charset=utf-8" }
