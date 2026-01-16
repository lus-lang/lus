/**
 * Client-side WASM loader for Lus playground
 * Loads WASM from static files fetched at build time
 */

export interface WasmRelease {
  version: string
  jsUrl: string
  wasmUrl: string
  isStable: boolean
}

export interface WasmReleases {
  stable: WasmRelease | null
  unstable: WasmRelease | null
}

interface WasmManifest {
  stable: { version: string } | null
  unstable: { version: string } | null
}

function toWasmRelease(
  entry: { version: string } | null,
  isStable: boolean,
): WasmRelease | null {
  if (!entry) return null

  const version = entry.version
  return {
    version,
    jsUrl: `/wasm/${encodeURIComponent(version)}/lus.js`,
    wasmUrl: `/wasm/${encodeURIComponent(version)}/lus.wasm`,
    isStable,
  }
}

/**
 * Fetches available WASM releases from the build-time manifest
 */
export async function getWasmReleases(): Promise<WasmReleases> {
  try {
    const res = await fetch("/wasm/manifest.json")
    if (!res.ok) {
      console.error(`Failed to fetch WASM manifest: ${res.status}`)
      return { stable: null, unstable: null }
    }

    const manifest: WasmManifest = await res.json()

    return {
      stable: toWasmRelease(manifest.stable, true),
      unstable: toWasmRelease(manifest.unstable, false),
    }
  } catch (e) {
    console.error("Failed to load WASM manifest:", e)
    return { stable: null, unstable: null }
  }
}

/**
 * Lus WASM module interface
 */
export interface LusModule {
  execute: (code: string) => string
  destroy: () => void
}

/**
 * Loads and initializes the Lus WASM module from a release
 */
export async function loadLusWasm(release: WasmRelease): Promise<LusModule> {
  // Fetch the JS loader
  const jsResponse = await fetch(release.jsUrl)
  let jsCode = await jsResponse.text()

  // Rewrite relative URLs to absolute paths before blob creation
  // Emscripten-generated code uses new URL('lus.wasm', import.meta.url)
  // which fails when loaded from a blob: URL
  const baseUrl = new URL(release.jsUrl, window.location.href).href
  const baseDir = baseUrl.substring(0, baseUrl.lastIndexOf("/") + 1)
  jsCode = jsCode.replace(
    /new URL\(['"]([^'"]+)['"]\s*,\s*import\.meta\.url\)/g,
    (_, relativePath) => `new URL("${baseDir}${relativePath}")`,
  )
  // Also fix the _scriptName assignment used for scriptDirectory
  jsCode = jsCode.replace(
    /var _scriptName\s*=\s*import\.meta\.url/g,
    `var _scriptName = "${baseUrl}"`,
  )

  // Create a blob URL to import the module
  const blob = new Blob([jsCode], { type: "application/javascript" })
  const blobUrl = URL.createObjectURL(blob)

  try {
    // Dynamically import the module
    const moduleFactory = (await import(/* @vite-ignore */ blobUrl)).default

    // Initialize with locateFile to find the WASM
    const Module = await moduleFactory({
      locateFile: (path: string) => {
        if (path.endsWith(".wasm")) {
          return release.wasmUrl
        }
        return path
      },
    })

    // Wrap the C functions
    const lus_create = Module.cwrap("lus_create", "number", [])
    const lus_execute = Module.cwrap("lus_execute", "string", [
      "number",
      "string",
    ])
    const lus_destroy = Module.cwrap("lus_destroy", null, ["number"])

    // Create a state
    const state = lus_create()
    if (!state) {
      throw new Error("Failed to create Lus state")
    }

    return {
      execute: (code: string) => lus_execute(state, code),
      destroy: () => {
        lus_destroy(state)
        URL.revokeObjectURL(blobUrl)
      },
    }
  } catch (e) {
    URL.revokeObjectURL(blobUrl)
    throw e
  }
}
