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

interface EmscriptenModule {
  HEAPU8: Uint8Array
  _free(pointer: number): void
  _malloc(size: number): number
  lengthBytesUTF8(value: string): number
  stringToUTF8(
    value: string,
    pointer: number,
    maxBytesToWrite: number,
  ): number
}

type WasmByteCall = (
  state: number,
  inputPointer: number,
  inputBytes: number,
) => number

const MAX_WASM32_INPUT_BYTES = 0xffff_fffe
const MAX_WASM32_OUTPUT_BYTES = 0xffff_ffff
const wasmOutputDecoder = new TextDecoder("utf-8", { fatal: true })

function decodeWasmOutput(
  module: EmscriptenModule,
  pointer: number,
  byteLength: number,
): string {
  const heap = module.HEAPU8
  if (
    !(heap instanceof Uint8Array) ||
    !Number.isSafeInteger(pointer) ||
    pointer < 0 ||
    pointer > heap.byteLength ||
    byteLength > heap.byteLength - pointer
  ) {
    throw new Error("WASM output is outside linear memory")
  }
  try {
    return wasmOutputDecoder.decode(heap.subarray(pointer, pointer + byteLength))
  } catch {
    throw new Error("WASM output is not valid UTF-8")
  }
}

export function callWasmUtf8(
  module: EmscriptenModule,
  call: WasmByteCall,
  outputLength: (state: number) => number,
  state: number,
  input: string,
): string {
  const inputBytes = module.lengthBytesUTF8(input)
  if (
    !Number.isSafeInteger(inputBytes) ||
    inputBytes < 0 ||
    inputBytes > MAX_WASM32_INPUT_BYTES
  ) {
    throw new Error("WASM source size is not representable in wasm32")
  }

  const allocationBytes = inputBytes + 1
  const inputPointer = module._malloc(allocationBytes)
  if (!Number.isSafeInteger(inputPointer) || inputPointer <= 0) {
    throw new Error("WASM source allocation failed")
  }

  try {
    const written = module.stringToUTF8(
      input,
      inputPointer,
      allocationBytes,
    )
    if (written !== inputBytes) {
      throw new Error("WASM source encoding failed")
    }

    const outputPointer = call(state, inputPointer, inputBytes)
    const outputBytes = outputLength(state)
    if (
      !Number.isSafeInteger(outputBytes) ||
      outputBytes < 0 ||
      outputBytes > MAX_WASM32_OUTPUT_BYTES
    ) {
      throw new Error("WASM output size is not representable in wasm32")
    }
    if (outputBytes === 0) return ""
    if (!Number.isSafeInteger(outputPointer) || outputPointer <= 0) {
      throw new Error("WASM output is unavailable")
    }
    return decodeWasmOutput(module, outputPointer, outputBytes)
  } finally {
    module._free(inputPointer)
  }
}

/**
 * Loads and initializes the Lus WASM module from a release
 */
export async function loadLusWasm(release: WasmRelease): Promise<LusModule> {
  // Fetch the JS loader
  const jsResponse = await fetch(release.jsUrl)
  if (!jsResponse.ok) {
    throw new Error(`Failed to fetch the WASM loader: ${jsResponse.status}`)
  }
  let jsCode = await jsResponse.text()

  // Rewrite relative URLs to absolute paths before blob creation
  // Emscripten-generated code uses new URL('lus.wasm', import.meta.url)
  // which fails when loaded from a blob: URL
  const baseUrl = new URL(release.jsUrl, globalThis.location.href).href
  const baseDir = baseUrl.substring(0, baseUrl.lastIndexOf("/") + 1)
  const wasmUrl = new URL(release.wasmUrl, globalThis.location.href).href
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
      print: () => {},
      printErr: () => {},
      locateFile: (path: string) => {
        if (path.endsWith(".wasm")) {
          return wasmUrl
        }
        return path
      },
    })

    // Wrap the C functions
    const lus_create = Module.cwrap("lus_create", "number", [])
    const lus_execute_bytes = Module.cwrap("lus_execute_bytes", "number", [
      "number",
      "number",
      "number",
    ]) as WasmByteCall
    const lus_output_length = Module.cwrap("lus_output_length", "number", [
      "number",
    ]) as (state: number) => number
    const lus_destroy = Module.cwrap("lus_destroy", null, ["number"])

    // Create a state
    const state = lus_create()
    if (!state) {
      throw new Error("Failed to create Lus state")
    }

    return {
      execute: (code: string) =>
        callWasmUtf8(
          Module,
          lus_execute_bytes,
          lus_output_length,
          state,
          code,
        ),
      destroy: () => {
        try {
          lus_destroy(state)
        } finally {
          URL.revokeObjectURL(blobUrl)
        }
      },
    }
  } catch (e) {
    URL.revokeObjectURL(blobUrl)
    throw e
  }
}
