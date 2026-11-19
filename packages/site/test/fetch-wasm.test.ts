import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { access, mkdtemp, readFile, rm } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { once } from "node:events"
import test from "node:test"

import { fetchWasmReleases } from "../scripts/fetch-wasm.mjs"

const VERSION = "v1.7.0"
const JAVASCRIPT = Buffer.from("export default function Lus() {}\n")
const WASM = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex")
}

function checksumManifest({
  javascript = digest(JAVASCRIPT),
  wasm = digest(WASM),
  extra = "",
} = {}) {
  return `${javascript}  lus.web.js\n${wasm}  lus.wasm\n${extra}`
}

function release(base, { prerelease = false, assets, version = VERSION } = {}) {
  const names = assets ?? ["SHA256SUMS", "lus.web.js", "lus.wasm"]
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
    `/download/${VERSION}/lus.web.js`,
    options.javascript ?? JAVASCRIPT,
    options.javascriptResponse,
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
    ...options,
  })
}

test("downloads the checksum manifest before verified release files", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: checksumManifest({
        extra: `${"a".repeat(64)}  lus-1.7.0-wasm.tar.gz\n`,
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
        `/download/${VERSION}/lus.web.js`,
        `/download/${VERSION}/lus.wasm`,
      ])
      assert.deepEqual(
        await readFile(join(outputDirectory, VERSION, "lus.js")),
        JAVASCRIPT,
      )
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
    fixture.route(`/download/${version}/lus.web.js`, JAVASCRIPT)
    fixture.route(`/download/${version}/lus.wasm`, WASM)

    await withOutputDirectory(async (outputDirectory) => {
      assert.deepEqual(await runFetch(fixture, outputDirectory), {
        stable: null,
        unstable: { version },
      })
      assert.deepEqual(await readFile(join(outputDirectory, version, "lus.js")), JAVASCRIPT)
    })
  })
})

test("requires the canonical web loader asset", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      selectedRelease: release(fixture.base, {
        assets: ["SHA256SUMS", "lus.js", "lus.wasm"],
      }),
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /missing lus\.web\.js/,
      )
    })
  })
})

test("requires a checksum release asset", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      selectedRelease: release(fixture.base, {
        assets: ["lus.web.js", "lus.wasm"],
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
      checksums: `${"a".repeat(63)}  lus.web.js\n${digest(WASM)}  lus.wasm\n`,
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
      checksums: `${checksumManifest()}${digest(JAVASCRIPT)}  lus.web.js\n`,
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /lists lus\.web\.js more than once/,
      )
    })
  })
})

test("requires checksum entries for every selected file", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: `${digest(JAVASCRIPT)}  lus.web.js\n`,
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
        access(join(outputDirectory, VERSION, "lus.js")),
        /ENOENT/,
      )
    })
  })
})

test("rejects a checksum mismatch before writing release files", async () => {
  await withReleaseServer(async (fixture) => {
    addStandardRoutes(fixture, {
      checksums: checksumManifest({ javascript: "0".repeat(64) }),
    })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /SHA-256 mismatch for lus\.web\.js/,
      )
      await assert.rejects(
        access(join(outputDirectory, VERSION, "lus.js")),
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
      (asset) => asset.name === "lus.web.js",
    ).browser_download_url = `${fixture.base}/download/other/lus.web.js`
    addStandardRoutes(fixture, { selectedRelease })
    await withOutputDirectory(async (outputDirectory) => {
      await assert.rejects(
        runFetch(fixture, outputDirectory),
        /unversioned URL for lus\.web\.js/,
      )
    })
  })
})

test("requires release files and checksums to share one origin", async () => {
  await withReleaseServer(async (fixture) => {
    const selectedRelease = release(fixture.base)
    selectedRelease.assets.find(
      (asset) => asset.name === "lus.web.js",
    ).browser_download_url = selectedRelease.assets.find(
      (asset) => asset.name === "lus.web.js",
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
        /lists lus\.web\.js more than once/,
      )
    })
  })
})
