import assert from "node:assert/strict"
import test from "node:test"

import { parseAssetLinks, type GitHubRelease } from "../src/lib/release.ts"

const TAG = "v2.0.0"
const BASE = `https://github.com/lus-lang/lus/releases/download/${TAG}`

function release(names: string[]): GitHubRelease {
  return {
    tag_name: TAG,
    published_at: "2026-11-19T00:00:00Z",
    html_url: `https://github.com/lus-lang/lus/releases/tag/${TAG}`,
    prerelease: false,
    assets: names.map((name) => ({
      name,
      browser_download_url: `${BASE}/${name}`,
    })),
    zipball_url: "https://api.github.com/repos/lus-lang/lus/zipball/v2.0.0",
    tarball_url: "https://api.github.com/repos/lus-lang/lus/tarball/v2.0.0",
  }
}

test("maps every 2.0 release asset to its download link", () => {
  const links = parseAssetLinks(
    release([
      "lus-v2.0.0-x86_64-linux-musl.tar.gz",
      "lus-v2.0.0-aarch64-linux-musl.tar.gz",
      "lus-v2.0.0-arm-linux-musleabihf.tar.gz",
      "lus-v2.0.0-riscv64-linux-musl.tar.gz",
      "lus-v2.0.0-loongarch64-linux-musl.tar.gz",
      "lus-v2.0.0-powerpc64le-linux-musl.tar.gz",
      "lus-v2.0.0-s390x-linux-musl.tar.gz",
      "lus-v2.0.0-x86_64-macos.tar.gz",
      "lus-v2.0.0-aarch64-macos.tar.gz",
      "lus-v2.0.0-x86_64-windows.zip",
      "lus-v2.0.0-aarch64-windows.zip",
      "lus-setup.exe",
      "lus.wasm",
      "lus-2.0.0.vsix",
      "SHA256SUMS",
    ]),
  )
  assert.deepEqual(links, {
    windowsInstaller: `${BASE}/lus-setup.exe`,
    windowsX64: `${BASE}/lus-v2.0.0-x86_64-windows.zip`,
    windowsArm64: `${BASE}/lus-v2.0.0-aarch64-windows.zip`,
    macosArm64: `${BASE}/lus-v2.0.0-aarch64-macos.tar.gz`,
    macosX64: `${BASE}/lus-v2.0.0-x86_64-macos.tar.gz`,
    linuxX64: `${BASE}/lus-v2.0.0-x86_64-linux-musl.tar.gz`,
    linuxArm64: `${BASE}/lus-v2.0.0-aarch64-linux-musl.tar.gz`,
    linuxArm32: `${BASE}/lus-v2.0.0-arm-linux-musleabihf.tar.gz`,
    linuxRiscv64: `${BASE}/lus-v2.0.0-riscv64-linux-musl.tar.gz`,
    linuxLoong64: `${BASE}/lus-v2.0.0-loongarch64-linux-musl.tar.gz`,
    linuxPpc64le: `${BASE}/lus-v2.0.0-powerpc64le-linux-musl.tar.gz`,
    linuxS390x: `${BASE}/lus-v2.0.0-s390x-linux-musl.tar.gz`,
    wasm: `${BASE}/lus.wasm`,
    checksums: `${BASE}/SHA256SUMS`,
    sourceZip: "https://api.github.com/repos/lus-lang/lus/zipball/v2.0.0",
    sourceTarball: "https://api.github.com/repos/lus-lang/lus/tarball/v2.0.0",
  })
})

test("leaves out the archives a release does not publish", () => {
  const links = parseAssetLinks(
    release(["lus-v1.9.0-x86_64-macos.tar.gz", "SHA256SUMS"]),
  )
  assert.equal(links.macosX64, undefined)
  assert.equal(links.windowsInstaller, undefined)
  assert.equal(links.checksums, `${BASE}/SHA256SUMS`)
})
