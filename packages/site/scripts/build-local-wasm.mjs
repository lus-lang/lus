import { spawnSync } from "node:child_process"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { stageLocalWasmPublic } from "./stage-local-wasm.mjs"

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const siteDirectory = resolve(scriptDirectory, "..")
const repositoryDirectory = resolve(siteDirectory, "../..")
const artifactDirectoryValue = process.env.LUS_WASM_ARTIFACT_DIR

if (!artifactDirectoryValue) {
  throw new Error("LUS_WASM_ARTIFACT_DIR must name the current WASM build")
}

const artifactDirectory = resolve(siteDirectory, artifactDirectoryValue)
const javascriptSource = join(artifactDirectory, "lus.web.js")
const wasmSource = join(artifactDirectory, "lus.wasm")
const versionHeader = await readFile(join(repositoryDirectory, "legacy/lus/src/lua.h"), "utf8")

function versionPart(name) {
  const match = versionHeader.match(new RegExp(`^#define ${name} (\\d+)$`, "m"))
  if (!match) throw new Error(`Missing canonical ${name} in lua.h`)
  return match[1]
}

const version = `v${versionPart("LUA_VERSION_MAJOR_N")}.${versionPart(
  "LUA_VERSION_MINOR_N",
)}.${versionPart("LUA_VERSION_RELEASE_N")}`
const javascript = await readFile(javascriptSource)
const wasm = await readFile(wasmSource)

if (javascript.length === 0) throw new Error("lus.web.js is empty")
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
const releaseUrl = `https://github.com/lus-lang/lus/releases/tag/${version}`
const sourceUrl = `https://github.com/lus-lang/lus/archive/refs/tags/${version}`
const localReleases = [
  {
    tag_name: version,
    published_at: "2026-08-30T00:00:00Z",
    html_url: releaseUrl,
    prerelease: false,
    assets: [
      {
        name: "lus.web.js",
        browser_download_url: `/wasm/${version}/lus.js`,
      },
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
    javascript,
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
