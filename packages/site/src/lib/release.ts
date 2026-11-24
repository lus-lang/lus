const GITHUB_REPO = "lus-lang/lus"

export interface ReleaseLinks {
  windowsInstaller?: string
  windowsX64?: string
  windowsArm64?: string
  macosArm64?: string
  macosX64?: string
  linuxX64?: string
  linuxArm64?: string
  linuxArm32?: string
  linuxRiscv64?: string
  linuxLoong64?: string
  linuxPpc64le?: string
  linuxS390x?: string
  wasm?: string
  checksums?: string
  sourceZip?: string
  sourceTarball?: string
}

export interface ReleaseInfo {
  version: string
  releaseDate: string
  links: ReleaseLinks
  htmlUrl: string
}

interface GitHubAsset {
  name: string
  browser_download_url: string
}

export interface GitHubRelease {
  tag_name: string
  published_at: string
  html_url: string
  prerelease: boolean
  assets: GitHubAsset[]
  zipball_url: string
  tarball_url: string
}

/*
** A release publishes one archive per target, named
** lus-<tag>-<target>.tar.gz, or .zip for Windows, which holds the install
** prefix with bin/lus, the embedding libraries, and lus.h. Beside the
** archives sit the Windows installer lus-setup.exe, lus.wasm, and the
** SHA256SUMS manifest.
*/
const TARGET_ARCHIVES = {
  windowsX64: "x86_64-windows.zip",
  windowsArm64: "aarch64-windows.zip",
  macosArm64: "aarch64-macos.tar.gz",
  macosX64: "x86_64-macos.tar.gz",
  linuxX64: "x86_64-linux-musl.tar.gz",
  linuxArm64: "aarch64-linux-musl.tar.gz",
  linuxArm32: "arm-linux-musleabihf.tar.gz",
  linuxRiscv64: "riscv64-linux-musl.tar.gz",
  linuxLoong64: "loongarch64-linux-musl.tar.gz",
  linuxPpc64le: "powerpc64le-linux-musl.tar.gz",
  linuxS390x: "s390x-linux-musl.tar.gz",
} as const

export function parseAssetLinks(release: GitHubRelease): ReleaseLinks {
  const assetMap = new Map(
    release.assets.map((a) => [a.name, a.browser_download_url])
  )
  const links: ReleaseLinks = {
    windowsInstaller: assetMap.get("lus-setup.exe"),
    wasm: assetMap.get("lus.wasm"),
    checksums: assetMap.get("SHA256SUMS"),
    sourceZip: release.zipball_url,
    sourceTarball: release.tarball_url,
  }
  for (const [key, suffix] of Object.entries(TARGET_ARCHIVES)) {
    links[key as keyof typeof TARGET_ARCHIVES] = assetMap.get(
      `lus-${release.tag_name}-${suffix}`
    )
  }
  return links
}

function formatReleaseDate(isoDate: string): string {
  return isoDate.split("T")[0]
}

/*
** One fetch per build: Layout renders on every page, so the release
** lookup is memoized at module level.
*/
let releasesPromise: Promise<GitHubRelease[] | null> | undefined

function isGitHubRelease(value: unknown): value is GitHubRelease {
  if (!value || typeof value !== "object") return false
  const release = value as Partial<GitHubRelease>
  return (
    typeof release.tag_name === "string" &&
    typeof release.published_at === "string" &&
    typeof release.html_url === "string" &&
    typeof release.prerelease === "boolean" &&
    typeof release.zipball_url === "string" &&
    typeof release.tarball_url === "string" &&
    Array.isArray(release.assets) &&
    release.assets.every(
      (asset) =>
        typeof asset.name === "string" &&
        typeof asset.browser_download_url === "string",
    )
  )
}

function fetchGitHubReleases(): Promise<GitHubRelease[] | null> {
  releasesPromise ??= (async () => {
    const localManifest = process.env.LUS_SITE_RELEASES_JSON
    if (localManifest !== undefined) {
      const releases: unknown = JSON.parse(localManifest)
      if (!Array.isArray(releases) || !releases.every(isGitHubRelease)) {
        throw new Error("LUS_SITE_RELEASES_JSON is not a release array")
      }
      return releases
    }
    try {
      const response = await fetch(
        `https://api.github.com/repos/${GITHUB_REPO}/releases`,
        {
          headers: {
            Accept: "application/vnd.github.v3+json",
          },
        }
      )

      if (!response.ok) {
        console.error(`GitHub API error: ${response.status}`)
        return null
      }

      return response.json()
    } catch (error) {
      console.error("Failed to fetch GitHub releases:", error)
      return null
    }
  })()
  return releasesPromise
}

export async function getLatestStableRelease(): Promise<ReleaseInfo | null> {
  const releases = await fetchGitHubReleases()
  if (!releases) return null

  const stable = releases.find((r) => !r.prerelease)
  if (!stable) return null

  return {
    version: stable.tag_name,
    releaseDate: formatReleaseDate(stable.published_at),
    links: parseAssetLinks(stable),
    htmlUrl: stable.html_url,
  }
}

export async function getLatestUnstableRelease(): Promise<ReleaseInfo | null> {
  const releases = await fetchGitHubReleases()
  if (!releases) return null

  const unstable = releases.find((r) => r.prerelease)
  if (!unstable) return null

  return {
    version: unstable.tag_name,
    releaseDate: formatReleaseDate(unstable.published_at),
    links: parseAssetLinks(unstable),
    htmlUrl: unstable.html_url,
  }
}

export async function getAllReleases(): Promise<{
  stable: ReleaseInfo | null
  unstable: ReleaseInfo | null
}> {
  const releases = await fetchGitHubReleases()

  if (!releases) {
    return { stable: null, unstable: null }
  }

  // Sort by published_at descending to ensure we get the latest releases
  const sorted = [...releases].sort(
    (a, b) =>
      new Date(b.published_at).getTime() - new Date(a.published_at).getTime()
  )

  const stableRelease = sorted.find((r) => !r.prerelease)
  const unstableRelease = sorted.find((r) => r.prerelease)

  return {
    stable: stableRelease
      ? {
          version: stableRelease.tag_name,
          releaseDate: formatReleaseDate(stableRelease.published_at),
          links: parseAssetLinks(stableRelease),
          htmlUrl: stableRelease.html_url,
        }
      : null,
    unstable: unstableRelease
      ? {
          version: unstableRelease.tag_name,
          releaseDate: formatReleaseDate(unstableRelease.published_at),
          links: parseAssetLinks(unstableRelease),
          htmlUrl: unstableRelease.html_url,
        }
      : null,
  }
}
