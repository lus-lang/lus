import { spawnSync } from "node:child_process"
import project from "../../../packaging/project.json" with { type: "json" }
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { localRuntimeVersion } from "./fetch-wasm.mjs"
import { stageLocalWasmPublic } from "./stage-local-wasm.mjs"

// Builds the site with a local lus.wasm as its only runtime. The module
// comes from LUS_WASM_ARTIFACT_DIR, or from packages/wasm/dist, where
// `mise run wasm` puts it.
const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const siteDirectory = resolve(scriptDirectory, "..")
const artifactDirectory = resolve(
  siteDirectory,
  process.env.LUS_WASM_ARTIFACT_DIR ?? "../wasm/dist",
)
const wasmSource = join(artifactDirectory, "lus.wasm")
const version = await localRuntimeVersion()
const wasm = await readFile(wasmSource)

if (
  wasm.length < 8 ||
  wasm[0] !== 0x00 ||
  wasm[1] !== 0x61 ||
  wasm[2] !== 0x73 ||
  wasm[3] !== 0x6d
) {
  throw new Error("lus.wasm does not have a WebAssembly header")
}

const astroBinary = join(
  siteDirectory,
  "node_modules/.bin",
  process.platform === "win32" ? "astro.cmd" : "astro",
)
const releaseUrl = `${project.repository}/releases/tag/${version}`
const sourceUrl = `${project.repository}/archive/refs/tags/${version}`
const localReleases = [
  {
    tag_name: version,
    published_at: "2026-08-30T00:00:00Z",
    html_url: releaseUrl,
    prerelease: false,
    assets: [
      {
        name: "lus.wasm",
        browser_download_url: `/wasm/${version}/lus.wasm`,
      },
    ],
    zipball_url: `${sourceUrl}.zip`,
    tarball_url: `${sourceUrl}.tar.gz`,
  },
]

const publicDirectory = await mkdtemp(join(tmpdir(), "lus-site-public-"))
try {
  await stageLocalWasmPublic({
    sourcePublicDirectory: join(siteDirectory, "public"),
    stagedPublicDirectory: publicDirectory,
    version,
    wasm,
  })

  const build = spawnSync(astroBinary, ["build"], {
    cwd: siteDirectory,
    env: {
      ...process.env,
      LUS_SITE_PUBLIC_DIR: publicDirectory,
      LUS_SITE_RELEASES_JSON: JSON.stringify(localReleases),
    },
    stdio: "inherit",
  })
  if (build.error) throw build.error
  if (build.status !== 0) {
    throw new Error(`Astro exited with status ${build.status ?? "unknown"}`)
  }
} finally {
  await rm(publicDirectory, { recursive: true, force: true })
}
