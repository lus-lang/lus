/**
 * Fetches verified WASM files from GitHub releases at build time.
 * Run this before `astro build` to include WASM in the static output.
 *
 * The playground runs lus.wasm through the lus-wasm host, which loads the
 * WASI module that Lus 2.0 and later releases ship. Each such release
 * contributes its lus.wasm, checked against its SHA256SUMS. A local build
 * of packages/wasm (made with `mise run wasm`) becomes the unstable
 * channel, so a checkout can try its own runtime in the playground.
 */

import { createHash } from "node:crypto"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { TextDecoder } from "node:util"

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const GITHUB_REPO = "lus-lang/lus"
const RELEASES_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases`
const OUTPUT_DIR = join(scriptDirectory, "..", "public", "wasm")
const CHECKSUM_ASSET = "SHA256SUMS"
const WASM_ASSET = "lus.wasm"
const LOCAL_WASM = join(scriptDirectory, "..", "..", "wasm", "dist", WASM_ASSET)
const RUNTIME_MANIFEST = join(
  scriptDirectory,
  "..",
  "..",
  "..",
  "runtime",
  "build.zig.zon",
)
/** The emscripten glue that releases before Lus 2.0 ship beside lus.wasm. */
const EMSCRIPTEN_ASSETS = new Set(["lus.js", "lus.web.js", "lus.node.js"])
const RELEASE_TAG_PATTERN = /^[0-9A-Za-z][0-9A-Za-z.+_-]*$/
const CHECKSUM_LINE_PATTERN = /^([0-9a-fA-F]{64}) [ *]([^\r\n]+)$/

function releaseAssetIndex(release) {
  if (!Array.isArray(release.assets)) {
    throw new Error(`Release ${release.tag_name} has no asset list`)
  }

  const assets = new Map()
  for (const asset of release.assets) {
    if (
      !asset ||
      typeof asset.name !== "string" ||
      typeof asset.browser_download_url !== "string"
    ) {
      throw new Error(`Release ${release.tag_name} has malformed asset metadata`)
    }
    if (assets.has(asset.name)) {
      throw new Error(
        `Release ${release.tag_name} lists ${asset.name} more than once`,
      )
    }
    assets.set(asset.name, asset.browser_download_url)
  }
  return assets
}

function requiredAsset(assets, release, name) {
  const url = assets.get(name)
  if (!url) {
    throw new Error(`Release ${release.tag_name} is missing ${name}`)
  }
  return url
}

function assetDirectory(url, release, name) {
  let parsed
  try {
    parsed = new URL(url)
  } catch (cause) {
    throw new Error(
      `Release ${release.tag_name} has an invalid URL for ${name}`,
      { cause },
    )
  }

  if (parsed.username || parsed.password) {
    throw new Error(`Release ${release.tag_name} has credentials in the ${name} URL`)
  }

  const loopback = ["127.0.0.1", "::1", "localhost"].includes(parsed.hostname)
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) {
    throw new Error(`Release ${release.tag_name} has an insecure URL for ${name}`)
  }

  const parts = parsed.pathname.split("/").filter(Boolean).map(decodeURIComponent)
  if (
    parts.length < 2 ||
    parts.at(-1) !== name ||
    parts.at(-2) !== release.tag_name
  ) {
    throw new Error(
      `Release ${release.tag_name} has an unversioned URL for ${name}`,
    )
  }

  return new URL(".", parsed)
}

function validateReleaseUrls(release, selected) {
  const checksumDirectory = assetDirectory(
    selected.checksums,
    release,
    CHECKSUM_ASSET,
  )

  const directory = assetDirectory(selected.wasm, release, WASM_ASSET)
  if (
    directory.origin !== checksumDirectory.origin ||
    directory.pathname !== checksumDirectory.pathname
  ) {
    throw new Error(
      `Release ${release.tag_name} serves ${WASM_ASSET} outside its checksum directory`,
    )
  }
}

/**
 * True when the release ships a lus.wasm that runs on the lus-wasm host.
 * Releases before Lus 2.0 ship an emscripten module together with its
 * JavaScript glue, and the playground leaves them out.
 */
export function isWasiRelease(release) {
  if (!Array.isArray(release?.assets)) return true
  const names = release.assets.map((asset) => asset?.name)
  return (
    names.includes(WASM_ASSET) &&
    !names.some((name) => EMSCRIPTEN_ASSETS.has(name))
  )
}

function hasWasmHeader(bytes) {
  return (
    bytes.length >= 8 &&
    bytes[0] === 0x00 &&
    bytes[1] === 0x61 &&
    bytes[2] === 0x73 &&
    bytes[3] === 0x6d
  )
}

/** Reads the runtime version from runtime/build.zig.zon, such as v2.0.0-dev. */
export async function localRuntimeVersion(manifestPath = RUNTIME_MANIFEST) {
  const source = await readFile(manifestPath, "utf8")
  const match = /^\s*\.version\s*=\s*"([0-9A-Za-z.+_-]+)"/m.exec(source)
  if (!match) throw new Error(`${manifestPath} has no version`)
  return `v${match[1]}`
}

/**
 * Reads a local lus.wasm, or returns null when there is none.
 */
async function readLocalWasm(path) {
  if (!path) return null
  let bytes
  try {
    bytes = await readFile(path)
  } catch (error) {
    if (error?.code === "ENOENT") return null
    throw error
  }
  if (!hasWasmHeader(bytes)) {
    throw new Error(`${path} does not have a WebAssembly header`)
  }
  return bytes
}

export function parseChecksumManifest(source) {
  if (typeof source !== "string") {
    throw new TypeError("The checksum manifest must be text")
  }

  const entries = new Map()
  const lines = source.split(/\r?\n/)
  if (lines.at(-1) === "") lines.pop()
  if (lines.length === 0) {
    throw new Error("SHA256SUMS is empty")
  }

  for (let index = 0; index < lines.length; index += 1) {
    const match = CHECKSUM_LINE_PATTERN.exec(lines[index])
    if (!match) {
      throw new Error(`SHA256SUMS has a malformed entry on line ${index + 1}`)
    }

    const [, digest, name] = match
    if (entries.has(name)) {
      throw new Error(`SHA256SUMS lists ${name} more than once`)
    }
    entries.set(name, digest.toLowerCase())
  }

  return entries
}

function requireChecksum(entries, name) {
  const digest = entries.get(name)
  if (!digest) {
    throw new Error(`SHA256SUMS is missing ${name}`)
  }
  return digest
}

function sha256(bytes, hashFactory) {
  if (typeof hashFactory !== "function") {
    throw new Error("The SHA-256 implementation is unavailable")
  }

  try {
    const hash = hashFactory("sha256")
    if (
      !hash ||
      typeof hash.update !== "function" ||
      typeof hash.digest !== "function"
    ) {
      throw new TypeError("The SHA-256 implementation is incomplete")
    }
    const digest = hash.update(bytes).digest("hex")
    if (!/^[0-9a-f]{64}$/.test(digest)) {
      throw new TypeError("The SHA-256 implementation returned an invalid digest")
    }
    return digest
  } catch (cause) {
    throw new Error("The SHA-256 implementation is unavailable", { cause })
  }
}

async function fetchBytes(url, name, fetchImpl) {
  const response = await fetchImpl(url, {
    headers: { "User-Agent": "lus-site-build" },
  })
  if (!response.ok) {
    throw new Error(`Failed to download ${name}: ${response.status}`)
  }

  try {
    return Buffer.from(await response.arrayBuffer())
  } catch (cause) {
    throw new Error(`Failed to read ${name}`, { cause })
  }
}

async function fetchChecksumManifest(url, fetchImpl) {
  const bytes = await fetchBytes(url, CHECKSUM_ASSET, fetchImpl)
  let text
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes)
  } catch (cause) {
    throw new Error("SHA256SUMS is not valid UTF-8", { cause })
  }
  return parseChecksumManifest(text)
}

function verifyBytes(bytes, name, expected, hashFactory) {
  const actual = sha256(bytes, hashFactory)
  if (actual !== expected) {
    throw new Error(`SHA-256 mismatch for ${name}`)
  }
}

async function downloadRelease(release, { fetchImpl, hashFactory, log }) {
  if (!release || !RELEASE_TAG_PATTERN.test(release.tag_name)) {
    throw new Error("The selected release has an invalid version tag")
  }

  const assets = releaseAssetIndex(release)
  const selected = {
    checksums: requiredAsset(assets, release, CHECKSUM_ASSET),
    wasm: requiredAsset(assets, release, WASM_ASSET),
  }
  validateReleaseUrls(release, selected)

  log(`  Downloading ${selected.checksums}`)
  const entries = await fetchChecksumManifest(selected.checksums, fetchImpl)
  const wasmChecksum = requireChecksum(entries, WASM_ASSET)

  sha256(Buffer.alloc(0), hashFactory)

  log(`  Downloading ${selected.wasm}`)
  const wasm = await fetchBytes(selected.wasm, WASM_ASSET, fetchImpl)

  verifyBytes(wasm, WASM_ASSET, wasmChecksum, hashFactory)

  return { version: release.tag_name, wasm }
}

async function fetchReleases(releasesUrl, fetchImpl) {
  const response = await fetchImpl(releasesUrl, {
    headers: {
      Accept: "application/vnd.github.v3+json",
      "User-Agent": "lus-site-build",
    },
  })
  if (!response.ok) {
    throw new Error(`GitHub API error: ${response.status}`)
  }

  const releases = await response.json()
  if (!Array.isArray(releases)) {
    throw new Error("The GitHub releases response must be an array")
  }
  return releases
}

export async function fetchWasmReleases({
  releasesUrl = RELEASES_URL,
  outputDirectory = OUTPUT_DIR,
  fetchImpl = globalThis.fetch,
  hashFactory = createHash,
  log = console.log,
  localWasmPath = process.env.LUS_SITE_LOCAL_WASM ?? LOCAL_WASM,
  localVersion = localRuntimeVersion,
} = {}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("The fetch implementation is unavailable")
  }

  log("Fetching releases from GitHub...")
  const releases = await fetchReleases(releasesUrl, fetchImpl)
  const sorted = releases.filter(isWasiRelease).sort(
    (a, b) =>
      new Date(b.published_at).getTime() - new Date(a.published_at).getTime(),
  )
  const downloads = []
  const manifest = { stable: null, unstable: null }

  for (const isStable of [true, false]) {
    const release = sorted.find((candidate) => candidate.prerelease === !isStable)
    if (!release) continue

    const type = isStable ? "stable" : "unstable"
    log(`\nDownloading ${type} release: ${release.tag_name}`)
    const download = await downloadRelease(release, {
      fetchImpl,
      hashFactory,
      log,
    })
    downloads.push(download)
    manifest[type] = { version: download.version }
  }

  const localWasm = await readLocalWasm(localWasmPath)
  if (localWasm) {
    const version = await localVersion()
    if (!RELEASE_TAG_PATTERN.test(version)) {
      throw new Error(`The local runtime version ${version} is not a valid tag`)
    }
    log(`\nUsing the local build ${localWasmPath} as ${version} (unstable)`)
    const index = downloads.findIndex((download) => download.version === version)
    if (index !== -1) downloads.splice(index, 1)
    if (manifest.stable?.version === version) manifest.stable = null
    downloads.push({ version, wasm: localWasm })
    manifest.unstable = { version }
  }

  for (const download of downloads) {
    const versionDirectory = join(outputDirectory, download.version)
    await mkdir(versionDirectory, { recursive: true })
    await writeFile(join(versionDirectory, WASM_ASSET), download.wasm)
  }

  await mkdir(outputDirectory, { recursive: true })
  const manifestPath = join(outputDirectory, "manifest.json")
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  log(`\nWrote manifest to ${manifestPath}`)
  log("Done!")

  return manifest
}

async function main() {
  await fetchWasmReleases()
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error)
    process.exitCode = 1
  })
}
