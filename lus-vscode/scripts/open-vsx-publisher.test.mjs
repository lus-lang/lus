import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";

import {
  buildPublisher,
  publisherExternalBuiltins,
  publisherVersion,
} from "./build-open-vsx-publisher.mjs";

function runPublisher(publisher, args, environment = {}) {
  const child = spawn(process.execPath, [publisher, ...args], {
    env: { ...process.env, ...environment },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (stdout += chunk));
  child.stderr.on("data", (chunk) => (stderr += chunk));
  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (status, signal) =>
      resolve({ signal, status, stderr, stdout }),
    );
  });
}

test("frozen Open VSX publisher is deterministic and constrained", async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "lus-ovsx-publisher-"));
  const first = path.join(temporary, "publisher-one.cjs");
  const second = path.join(temporary, "publisher-two.cjs");
  const firstEvidence = await buildPublisher(first);
  const secondEvidence = await buildPublisher(second);
  const releaseManifest = JSON.parse(
    await readFile(new URL("../../release/manifest.json", import.meta.url), "utf8"),
  );
  assert.equal(firstEvidence.version, publisherVersion);
  assert.equal(
    firstEvidence.sha256,
    releaseManifest.components.vscodePublisher.sha256,
    "publisher bytes differ from the tagged release anchor",
  );
  assert.deepEqual(
    firstEvidence.externalBuiltins,
    publisherExternalBuiltins,
  );
  assert.match(firstEvidence.noticeSha256, /^[0-9a-f]{64}$/);
  assert.ok(
    firstEvidence.packages.some(
      (dependency) =>
        dependency.name === "ovsx" && dependency.version === publisherVersion,
    ),
  );
  for (const dependency of firstEvidence.packages) {
    assert.match(dependency.name, /\S/);
    assert.match(dependency.version, /^\d+\.\d+\.\d+/);
    assert.match(dependency.license, /\S/);
    assert.ok(dependency.licenseFiles.length > 0);
  }
  assert.equal(firstEvidence.sha256, secondEvidence.sha256);
  assert.deepEqual(await readFile(first), await readFile(second));

  const version = await runPublisher(first, ["--version"]);
  assert.equal(version.status, 0, version.stderr);
  assert.equal(version.stdout.trim(), publisherVersion);

  const vsix = path.join(temporary, "fixture.vsix");
  const payload = Buffer.from("exact verified VSIX bytes\n", "utf8");
  await writeFile(vsix, payload);

  const missingToken = await runPublisher(first, [vsix]);
  assert.equal(missingToken.status, 1);
  assert.match(missingToken.stderr, /OVSX_PAT is required/);

  const relativePath = await runPublisher(first, ["fixture.vsix"], {
    OVSX_PAT: "fixture-token",
  });
  assert.equal(relativePath.status, 1);
  assert.match(relativePath.stderr, /usage: publisher/);

  let request;
  const server = http.createServer((incoming, response) => {
    const chunks = [];
    incoming.on("data", (chunk) => chunks.push(chunk));
    incoming.on("end", () => {
      request = {
        body: Buffer.concat(chunks),
        method: incoming.method,
        url: incoming.url,
      };
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          name: "lus",
          namespace: "lus",
          targetPlatform: "universal",
          version: "1.7.0",
        }),
      );
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    const published = await runPublisher(first, [vsix], {
      NO_PROXY: "127.0.0.1",
      OVSX_PAT: "fixture-token",
      OVSX_REGISTRY_URL: `http://127.0.0.1:${address.port}`,
      no_proxy: "127.0.0.1",
    });
    assert.equal(published.status, 0, published.stderr);
    assert.match(published.stdout, /Published lus\.lus v1\.7\.0/);
  } finally {
    server.close();
    await once(server, "close");
  }
  assert.equal(request?.method, "POST");
  assert.equal(request?.url, "/api/-/publish?token=fixture-token");
  assert.deepEqual(request?.body, payload);
});
