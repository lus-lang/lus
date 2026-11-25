import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

// lib/install.ts imports a ?raw file, which plain node cannot load, so the
// constant is read from the source
const install = readFileSync(new URL("../src/lib/install.ts", import.meta.url), "utf8")
const prompts = readFileSync(new URL("../../../.agents/prompt.md", import.meta.url), "utf8")
const project = JSON.parse(readFileSync(new URL("../../../packaging/project.json", import.meta.url), "utf8"))

test("the masthead prompt is the first prompt of .agents/prompt.md", () => {
  const sh = install.match(/export const INSTALL_SH = `([^`]+)`/)![1].replace("${project.site}", project.site)
  const template = install.match(/export const AGENT_PROMPT = `((?:[^`\\]|\\.)+)`/)![1]
  const masthead = template.replace("${INSTALL_SH}", sh).replace(/\\`/g, "`")
  const first = prompts.match(/```text\n([\s\S]*?)\n```/)![1]
  assert.equal(masthead, first)
})
