import assert from "node:assert/strict"
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { stageLocalWasmPublic } from "../scripts/stage-local-wasm.mjs"

test("local WASM staging replaces stale versions and preserves other public assets", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "lus-site-stage-test-"))
  try {
    const source = join(workspace, "source")
    const staged = join(workspace, "staged")
    await mkdir(join(source, "wasm", "stale-version"), { recursive: true })
    await mkdir(staged)
    await writeFile(join(source, "favicon.svg"), "site asset")
    await writeFile(join(source, "wasm", "manifest.json"), "stale manifest")
    await writeFile(
      join(source, "wasm", "stale-version", "lus.wasm"),
      "stale runtime",
    )

    await stageLocalWasmPublic({
      sourcePublicDirectory: source,
      stagedPublicDirectory: staged,
      version: "v2.0.0",
      wasm: Buffer.from([0x00, 0x61, 0x73, 0x6d]),
    })

    assert.equal(await readFile(join(staged, "favicon.svg"), "utf8"), "site asset")
    assert.deepEqual((await readdir(join(staged, "wasm"))).sort(), [
      "manifest.json",
      "v2.0.0",
    ])
    assert.deepEqual(await readdir(join(staged, "wasm", "v2.0.0")), [
      "lus.wasm",
    ])
    assert.deepEqual(
      await readFile(join(staged, "wasm", "v2.0.0", "lus.wasm")),
      Buffer.from([0x00, 0x61, 0x73, 0x6d]),
    )
    await assert.rejects(access(join(staged, "wasm", "stale-version")))

    assert.equal(
      await readFile(join(source, "wasm", "stale-version", "lus.wasm"), "utf8"),
      "stale runtime",
    )
  } finally {
    await rm(workspace, { recursive: true, force: true })
  }
})
