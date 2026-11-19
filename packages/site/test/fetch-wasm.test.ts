import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { once } from "node:events"
import test from "node:test"

import {
  fetchWasmReleases,
  localRuntimeVersion,
} from "../scripts/fetch-wasm.mjs"

const VERSION = "v2.0.0"
const WASM = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex")
}

function checksumManifest({ wasm = digest(WASM), extra = "" } = {}) {
  return `${wasm}  lus.wasm\n${extra}`
}

function release(base, { prerelease = false, assets, version = VERSION } = {}) {
  const names = assets ?? ["SHA256SUMS", "lus.wasm"]
  return {
    tag_name: version,
    published_at: "2026-08-30T00:00:00Z",
    prerelease,
    assets: names.map((name) => ({
      name,
      browser_download_url: `${base}/download/${version}/${name}`,
    })),
  }
}

async function withReleaseServer(run) {
  const routes = new Map()
  const requests = []
  const server = createServer((request, response) => {
    requests.push(request.url)
    const route = routes.get(request.url)
    if (!route) {
      response.writeHead(404)
      response.end("missing")
      return
    }

    response.writeHead(route.status ?? 200, route.headers)
    response.end(route.body)
  })

  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  const address = server.address()
  assert.notEqual(address, null)
  assert.equal(typeof address, "object")
  const base = `http://127.0.0.1:${address.port}`

  try {
    await run({
      base,
      requests,
      route(path, body, options = {}) {
        routes.set(path, { body, ...options })
      },
    })
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()))
    })
  }
}

async function withOutputDirectory(run) {
  const directory = await mkdtemp(join(tmpdir(), "lus-site-wasm-test-"))
  try {
    await run(directory)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

function addStandardRoutes(fixture, options = {}) {
  const selectedRelease = options.selectedRelease ?? release(fixture.base)
  fixture.route(
    "/api/releases",
    JSON.stringify(options.releases ?? [selectedRelease]),
    { headers: { "Content-Type": "application/json" } },
  )
  fixture.route(
    `/download/${VERSION}/SHA256SUMS`,
    options.checksums ?? checksumManifest(),
    options.checksumResponse,
  )
  fixture.route(
    `/download/${VERSION}/lus.wasm`,
    options.wasm ?? WASM,
    options.wasmResponse,
  )
}

async function runFetch(fixture, outputDirectory, options = {}) {
  return fetchWasmReleases({
    releasesUrl: `${fixture.base}/api/releases`,
    outputDirectory,
    log() {},
    localWasmPath: null,
    ...options,
  })
}

test("downloads the checksum manifest before verified release files", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: checksumManifest({
        extra: `${"a".repeat(64)}  lus-2.0.0-wasm.tar.gz\n`,
      }),
    })

    await withOutputDirectory(async (outputDirectory) => {
      assert.deepEqual(await runFetch(fixture, outputDirectory), {
        stable: { version: VERSION },
        unstable: null,
      })
      assert.deepEqual(fixture.requests, [
        "/api/releases",
        `/download/${VERSION}/SHA256SUMS`,
        `/download/${VERSION}/lus.wasm`,
      ])
      assert.deepEqual(
        await readFile(join(outputDirectory, VERSION, "lus.wasm")),
        WASM,
      )
      assert.deepEqual(
        JSON.parse(await readFile(join(outputDirectory, "manifest.json"), "utf8")),
        { stable: { version: VERSION }, unstable: null },
      )
    })
  })
})

test("accepts a safe versioned unstable release tag", async () => {
  const version = "unstable-deadbee"
  await withReleaseServer(async (fixture) => {
    const selectedRelease = release(fixture.base, {
      prerelease: true,
      version,
    })
    fixture.route("/api/releases", JSON.stringify([selectedRelease]), {
      headers: { "Content-Type": "application/json" },
    })
    fixture.route(`/download/${version}/SHA256SUMS`, checksumManifest())
    fixture.route(`/download/${version}/lus.wasm`, WASM)

    await withOutputDirectory(async (outputDirectory) => {
      assert.deepEqual(await runFetch(fixture, outputDirectory), {
        stable: null,
        unstable: { version },
      })
      assert.deepEqual(await readFile(join(outputDirectory, version, "lus.wasm")), WASM)
    })
  })
})

test("skips releases that ship the emscripten module", async () => {
  await withReleaseServer(async (fixture) => {
    const legacy = release(fixture.base, {
      version: "v1.7.0",
      assets: ["SHA256SUMS", "lus.web.js", "lus.wasm"],
    })
    legacy.published_at = "2026-09-30T00:00:00Z"
    addStandardRoutes(fixture, { releases: [legacy, release(fixture.base)] })
    await withOutputDirectory(async (outputDirectory) => {
      assert.deepEqual(await runFetch(fixture, outputDirectory), {
        stable: { version: VERSION },
        unstable: null,
      })
      assert.ok(!fixture.requests.some((url) => url.includes("v1.7.0")))
    })
  })
})

test("skips releases without a WebAssembly module", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      releases: [
        release(fixture.base, { version: "v1.0.0", assets: ["lus.js", "lus.wasm"] }),
        release(fixture.base, { version: "binaries", assets: ["lus-linux"] }),
      ],
    })
    await withOutputDirectory(async (outputDirectory) => {
      assert.deepEqual(await runFetch(fixture, outputDirectory), {
        stable: null,
        unstable: null,
      })
      assert.deepEqual(fixture.requests, ["/api/releases"])
    })
  })
})

test("stages a local build as the unstable channel", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture)
    await withOutputDirectory(async (outputDirectory) => {
      const localWasmPath = join(outputDirectory, "local.wasm")
      const local = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x01])
      await writeFile(localWasmPath, local)
      assert.deepEqual(
        await runFetch(fixture, outputDirectory, {
          localWasmPath,
          localVersion: async () => "v2.1.0-dev",
        }),
        { stable: { version: VERSION }, unstable: { version: "v2.1.0-dev" } },
      )
      assert.deepEqual(
        await readFile(join(outputDirectory, "v2.1.0-dev", "lus.wasm")),
        local,
      )
    })
  })
})

test("ignores a missing local build and rejects one without a WebAssembly header", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture)
    await withOutputDirectory(async (outputDirectory) => {
      const localWasmPath = join(outputDirectory, "local.wasm")
      assert.deepEqual(
        await runFetch(fixture, outputDirectory, { localWasmPath }),
        { stable: { version: VERSION }, unstable: null },
      )
      await writeFile(localWasmPath, "not wasm")
      await assert.rejects(
        runFetch(fixture, outputDirectory, { localWasmPath }),
        /does not have a WebAssembly header/,
      )
    })
  })
})

test("reads the local runtime version from build.zig.zon", async () => {
  assert.match(await localRuntimeVersion(), /^v[0-9]+\.[0-9]+\.[0-9]+/)
})

test("requires a checksum release asset", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      selectedRelease: release(fixture.base, {
        assets: ["lus.wasm"],
      }),
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /missing SHA256SUMS/,
      )
    })
  })
})

test("fails when the checksum file cannot be downloaded", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksumResponse: { status: 404 },
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /Failed to download SHA256SUMS: 404/,
      )
      assert.deepEqual(fixture.requests, [
        "/api/releases",
        `/download/${VERSION}/SHA256SUMS`,
      ])
    })
  })
})

test("rejects malformed checksum entries", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: `${"a".repeat(63)}  lus.wasm\n`,
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /malformed entry on line 1/,
      )
    })
  })
})

test("rejects duplicate checksum entries", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: `${checksumManifest()}${digest(WASM)}  lus.wasm\n`,
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /lists lus\.wasm more than once/,
      )
    })
  })
})

test("requires checksum entries for every selected file", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: `${digest(WASM)}  lus.wasm.sig\n`,
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /SHA256SUMS is missing lus\.wasm/,
      )
    })
  })
})

test("fails before artifact downloads when SHA-256 is unavailable", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture)
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory, { hashFactory: null }),
        /SHA-256 implementation is unavailable/,
      )
      assert.deepEqual(fixture.requests, [
        "/api/releases",
        `/download/${VERSION}/SHA256SUMS`,
      ])
    })
  })
})

test("fails when a selected release file is missing", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      wasmResponse: { status: 404 },
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /Failed to download lus\.wasm: 404/,
      )
      await assert.rejects(
        access(join(outputDirectory, VERSION, "lus.wasm")),
        /ENOENT/,
      )
    })
  })
})

test("rejects a checksum mismatch before writing release files", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: checksumManifest({ wasm: "0".repeat(64) }),
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /SHA-256 mismatch for lus\.wasm/,
      )
      await assert.rejects(
        access(join(outputDirectory, VERSION, "lus.wasm")),
        /ENOENT/,
      )
      await assert.rejects(
        access(join(outputDirectory, "manifest.json")),
        /ENOENT/,
      )
    })
  })
})

test("requires release files and checksums to share one versioned directory", async () => {
  await withReleaseServer(async (fixture) => {
    const selectedRelease = release(fixture.base)
    selectedRelease.assets.find(
      (asset) => asset.name === "lus.wasm",
    ).browser_download_url = `${fixture.base}/download/other/lus.wasm`
    addStandardRoutes(fixture, { selectedRelease })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /unversioned URL for lus\.wasm/,
      )
    })
  })
})

test("requires release files and checksums to share one origin", async () => {
  await withReleaseServer(async (fixture) => {
    const selectedRelease = release(fixture.base)
    selectedRelease.assets.find(
      (asset) => asset.name === "lus.wasm",
    ).browser_download_url = selectedRelease.assets.find(
      (asset) => asset.name === "lus.wasm",
    ).browser_download_url.replace("127.0.0.1", "localhost")
    addStandardRoutes(fixture, { selectedRelease })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /outside its checksum directory/,
      )
    })
  })
})

test("rejects duplicate release asset names", async () => {
  await withReleaseServer(async (fixture) => {
    const selectedRelease = release(fixture.base)
    selectedRelease.assets.push({ ...selectedRelease.assets[1] })
    addStandardRoutes(fixture, { selectedRelease })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /lists lus\.wasm more than once/,
      )
    })
  })
})
