/**
 * Client-side helpers for the Lus playground. The site build places each
 * runtime at /wasm/<version>/lus.wasm and lists the channels in
 * /wasm/manifest.json. The playground worker loads the module through the
 * lus-wasm host, which is bundled with the worker.
 */

export interface WasmRelease {
  version: string
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

export function toWasmRelease(
  entry: { version: string } | null,
  isStable: boolean,
): WasmRelease | null {
  if (!entry) return null

  const version = entry.version
  return {
    version,
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
 * The runtime as the playground worker sees it.
 */
export interface LusModule {
  execute: (code: string) => string
  destroy: () => void
}

/** The part of the lus-wasm host that the playground uses. */
export interface LusHost {
  readonly dead: boolean
  create(): number
  execute(state: number, code: string): string
  destroy(state: number): void
}

/**
 * Wraps one long-lived state of `lus`. When a program calls `os.exit`,
 * the host replaces its WebAssembly instance, so the next run starts
 * over in a fresh state instead of reporting a stopped runtime.
 */
export function playgroundSession(lus: LusHost): LusModule {
  let state = lus.create()
  return {
    execute(code: string) {
      if (lus.dead) state = lus.create()
      return lus.execute(state, code)
    },
    destroy() {
      lus.destroy(state)
    },
  }
}
