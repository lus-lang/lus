// Runs install.sh against a release served from a local HTTPS server.
//
// The release holds an archive built from a real install prefix, which
// defaults to runtime/zig-out (run `zig build` in runtime first) and can
// be set with LUS_INSTALL_TEST_PREFIX. Run with:
//
//   node --test packaging/install/install.test.mjs

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const installer = path.join(here, "install.sh");
const certificate = path.join(here, "fixtures", "localhost-cert.pem");
const privateKey = path.join(here, "fixtures", "localhost-key.pem");
const prefix = path.resolve(
  process.env.LUS_INSTALL_TEST_PREFIX ?? path.join(root, "runtime", "zig-out"),
);

// The archive install.sh picks on this host, mirroring its detection.
function hostTarget() {
  const arch = { x64: "x86_64", arm64: "aarch64" }[process.arch];
  if (arch === undefined) return undefined;
  if (process.platform === "linux") return `${arch}-linux-musl`;
  if (process.platform === "darwin") {
    if (arch === "x86_64") {
      try {
        const translated = execFileSync("sysctl", ["-n", "sysctl.proc_translated"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        });
        if (translated.trim() === "1") return "aarch64-macos";
      } catch {
        // Intel Macs have no sysctl.proc_translated.
      }
    }
    return `${arch}-macos`;
  }
  return undefined;
}

const target = hostTarget();
const binary = path.join(prefix, "bin", "lus");
const skip =
  target === undefined
    ? `install.sh has no release archive for ${process.platform} ${process.arch}`
    : !existsSync(binary)
      ? `${binary} is missing. Run zig build in runtime first.`
      : false;

const version = readFileSync(path.join(root, "runtime", "build.zig.zon"), "utf8").match(
  /^\s*\.version = "([^"]+)",/m,
)[1];
const tag = `v${version}`;
const asset = `lus-${tag}-${target}.tar.gz`;
// Another target's archive, so the tests see that install.sh picks its own.
const otherTarget = target === "x86_64-macos" ? "aarch64-macos" : "x86_64-macos";
const otherAsset = `lus-${tag}-${otherTarget}.tar.gz`;

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

let workspace;
let server;
let baseUrl;
let release;
const requests = [];

before(async () => {
  if (skip) return;
  workspace = await mkdtemp(path.join(os.tmpdir(), "lus-install-test-"));
  const archivePath = path.join(workspace, asset);
  execFileSync("tar", ["-C", prefix, "-czf", archivePath, "."]);
  const archive = await readFile(archivePath);
  const files = {
    [asset]: archive,
    [otherAsset]: Buffer.from("another target\n"),
    "lus.wasm": Buffer.from("not a module\n"),
  };
  const sums = Object.keys(files)
    .sort()
    .map((name) => `${sha256(files[name])}  ${name}\n`)
    .join("");
  release = { ...files, SHA256SUMS: Buffer.from(sums) };

  server = https.createServer(
    { cert: await readFile(certificate), key: await readFile(privateKey) },
    (request, response) => {
      requests.push(request.url);
      const name = request.url.startsWith("/release/")
        ? decodeURIComponent(request.url.slice("/release/".length))
        : undefined;
      const body = name === undefined ? undefined : release[name];
      if (body === undefined) {
        response.writeHead(404).end("not found\n");
        return;
      }
      response.writeHead(200, { "Content-Length": body.length }).end(body);
    },
  );
  server.listen(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  baseUrl = `https://localhost:${server.address().port}/release`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  if (workspace) await rm(workspace, { recursive: true, force: true });
});

// The server runs in this process, so the installer runs asynchronously.
function run(command, args, extraEnvironment = {}) {
  const environment = { ...process.env };
  delete environment.LUS_VERSION;
  delete environment.LUS_INSTALL_DIR;
  Object.assign(environment, {
    LUS_RELEASE_BASE_URL: baseUrl,
    CURL_CA_BUNDLE: certificate,
    SSL_CERT_FILE: certificate,
    ...extraEnvironment,
  });
  const child = spawn(command, args, {
    cwd: workspace,
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk));
  child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk));
  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

async function freshDirectory(name) {
  const directory = path.join(workspace, name);
  await rm(directory, { recursive: true, force: true });
  return directory;
}

async function checkInstalled(directory) {
  const lus = path.join(directory, "lus");
  const reported = await run(lus, ["-v"]);
  assert.equal(reported.status, 0, reported.stderr);
  assert.ok(
    (reported.stdout + reported.stderr).includes(`Lus ${version}`),
    `lus -v printed ${reported.stdout}${reported.stderr}`,
  );

  const script = path.join(workspace, "hello.lus");
  await writeFile(script, 'print("installer-source-ok")\n');
  const executed = await run(lus, [script]);
  assert.equal(executed.status, 0, executed.stderr);
  assert.equal(executed.stdout.trim(), "installer-source-ok");
}

test("installs lus from a pinned release", { skip }, async () => {
  const directory = await freshDirectory("pinned");
  requests.length = 0;
  const result = await run("sh", [installer, "--version", version, "--dir", directory]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /checksum verified/);
  assert.deepEqual(requests, ["/release/SHA256SUMS", `/release/${asset}`]);
  await checkInstalled(directory);
});

test("finds the latest archive for this host in SHA256SUMS", { skip }, async () => {
  const directory = await freshDirectory("latest");
  requests.length = 0;
  const result = await run("sh", [installer], { LUS_INSTALL_DIR: directory });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.deepEqual(requests, ["/release/SHA256SUMS", `/release/${asset}`]);
  await checkInstalled(directory);
});

test("rejects an archive that does not match SHA256SUMS", { skip }, async () => {
  const directory = await freshDirectory("tampered");
  await mkdir(directory, { recursive: true });
  const original = release[asset];
  release[asset] = Buffer.concat([original, Buffer.from([0])]);
  try {
    const result = await run("sh", [installer, "--version", tag, "--dir", directory]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /checksum mismatch/);
    assert.equal(existsSync(path.join(directory, "lus")), false);
  } finally {
    release[asset] = original;
  }
});

test("rejects a release with no archive for this host", { skip }, async () => {
  const directory = await freshDirectory("missing");
  const sums = release.SHA256SUMS;
  release.SHA256SUMS = Buffer.from(
    sums
      .toString("utf8")
      .split("\n")
      .filter((line) => !line.endsWith(asset))
      .join("\n"),
  );
  try {
    const result = await run("sh", [installer, "--dir", directory]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(`no single archive for ${target}`));
    assert.equal(existsSync(path.join(directory, "lus")), false);
  } finally {
    release.SHA256SUMS = sums;
  }
});
