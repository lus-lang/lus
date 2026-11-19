import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { Lus } from "lus-wasm/browser"

import {
  playgroundSession,
  toWasmRelease,
  type LusHost,
} from "../src/lib/wasm-loader.ts"

const LOCAL_WASM = fileURLToPath(
  new URL("../../wasm/dist/lus.wasm", import.meta.url),
)

async function localWasm(): Promise<Uint8Array | null> {
  try {
    return await readFile(LOCAL_WASM)
  } catch {
    return null
  }
}

test("maps a manifest entry to its versioned module URL", () => {
  assert.equal(toWasmRelease(null, true), null)
  assert.deepEqual(toWasmRelease({ version: "v2.0.0-dev" }, false), {
    version: "v2.0.0-dev",
    wasmUrl: "/wasm/v2.0.0-dev/lus.wasm",
    isStable: false,
  })
})

test("a session keeps one state and replaces it after the instance ends", () => {
  const calls: string[] = []
  let next = 1
  const host = {
    dead: false,
    create() {
      calls.push("create")
      return next++
    },
    execute(state: number, code: string) {
      calls.push(`execute ${state} ${code}`)
      return ""
    },
    destroy(state: number) {
      calls.push(`destroy ${state}`)
    },
  } satisfies LusHost

  const session = playgroundSession(host)
  session.execute("a")
  session.execute("b")
  host.dead = true
  session.execute("c")
  session.destroy()
  assert.deepEqual(calls, [
    "create",
    "execute 1 a",
    "execute 1 b",
    "create",
    "execute 2 c",
    "destroy 2",
  ])
})

test("runs playground input through lus.wasm", async (t) => {
  const bytes = await localWasm()
  if (!bytes) {
    t.skip("packages/wasm/dist/lus.wasm is not built (run mise run wasm)")
    return
  }
  const session = playgroundSession(await Lus.load(bytes))
  try {
    assert.equal(session.execute("1 + 2"), "3\n")
    assert.equal(session.execute("global x = 40"), "")
    assert.equal(session.execute("x + 2"), "42\n")
    assert.equal(session.execute('print(`$(#"héllo")`)'), "5\n")
    assert.match(session.execute('error("boom")'), /boom/)
    assert.match(session.execute("os.exit(3)"), /exited with status 3/)
    assert.equal(session.execute('print("after exit")'), "after exit\n")
  } finally {
    session.destroy()
  }
})
