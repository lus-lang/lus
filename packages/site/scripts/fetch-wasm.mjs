/**
 * Fetches verified WASM files from GitHub releases at build time.
 * Run this before `astro build` to include WASM in the static output.
 */

import { createHash } from "node:crypto"
import { mkdir, writeFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { TextDecoder } from "node:util"

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const GITHUB_REPO = "lus-lang/lus"
const RELEASES_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases`
const OUTPUT_DIR = join(scriptDirectory, "..", "public", "wasm")
const CHECKSUM_ASSET = "SHA256SUMS"
const JAVASCRIPT_ASSET = "lus.web.js"
const WASM_ASSET = "lus.wasm"
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

  for (const [name, url] of [
    [JAVASCRIPT_ASSET, selected.javascript],
    [WASM_ASSET, selected.wasm],
  ]) {
    const directory = assetDirectory(url, release, name)
    if (
      directory.origin !== checksumDirectory.origin ||
      directory.pathname !== checksumDirectory.pathname
    ) {
      throw new Error(
        `Release ${release.tag_name} serves ${name} outside its checksum directory`,
      )
    }
  }
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
    javascript: requiredAsset(assets, release, JAVASCRIPT_ASSET),
    wasm: requiredAsset(assets, release, WASM_ASSET),
  }
  validateReleaseUrls(release, selected)

  log(`  Downloading ${selected.checksums}`)
  const entries = await fetchChecksumManifest(selected.checksums, fetchImpl)
  const javascriptChecksum = requireChecksum(entries, JAVASCRIPT_ASSET)
  const wasmChecksum = requireChecksum(entries, WASM_ASSET)

  sha256(Buffer.alloc(0), hashFactory)

  log(`  Downloading ${selected.javascript}`)
  const javascript = await fetchBytes(
    selected.javascript,
    JAVASCRIPT_ASSET,
    fetchImpl,
  )
  log(`  Downloading ${selected.wasm}`)
  const wasm = await fetchBytes(selected.wasm, WASM_ASSET, fetchImpl)

  verifyBytes(javascript, JAVASCRIPT_ASSET, javascriptChecksum, hashFactory)
  verifyBytes(wasm, WASM_ASSET, wasmChecksum, hashFactory)

  return { version: release.tag_name, javascript, wasm }
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
} = {}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("The fetch implementation is unavailable")
  }

  log("Fetching releases from GitHub...")
  const releases = await fetchReleases(releasesUrl, fetchImpl)
  const sorted = [...releases].sort(
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

  for (const download of downloads) {
    const versionDirectory = join(outputDirectory, download.version)
    await mkdir(versionDirectory, { recursive: true })
    await writeFile(join(versionDirectory, "lus.js"), download.javascript)
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
