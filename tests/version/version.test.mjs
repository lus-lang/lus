// Pins the contract of `lus version` and `lus +REQUEST`
// (spec/tools/version.md): the subcommands, their JSON output, the exit
// statuses, the directory layout, and the verification of releases. A
// loopback server serves a release index signed by a test root key.
//
//   node tests/version/version.test.mjs runtime/zig-out/bin/lus

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, readFileSync, readlinkSync } from "node:fs";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { gzipSync } from "node:zlib";
import { keyList, keyPair, serve, sha256, signDocument, ustar } from "../lib/release.mjs";
import { addRelease } from "../../tools/release-index.mjs";

const lus = path.resolve(process.argv[2] ?? process.env.LUS_BIN ?? "runtime/zig-out/bin/lus");
const windows = process.platform === "win32";
const exe = windows ? "lus.exe" : "lus";

function target() {
  const arch = { x64: "x86_64", arm64: "aarch64" }[process.arch];
  if (process.platform === "darwin") return `${arch}-macos`;
  if (windows) return "x86_64-windows";
  return `${arch}-linux-musl`;
}

const root = keyPair();
const signing = { ...keyPair(), id: "lus-test-1" };
const routes = new Map();
let srv;
let home;
let archive;

function release(version, channel, data = archive) {
  return {
    version,
    channel,
    published: "2026-06-01T00:00:00Z",
    assets: { [target()]: { url: `${srv.base}/a/${version}.tar.gz`, sha256: sha256(data), size: data.length } },
  };
}

function setIndex({ signed = "2026-06-02T00:00:00Z", releases, key = signing } = {}) {
  const doc = {
    schema: 1,
    key: key.id,
    signed,
    channels: { stable: "2.0.2", unstable: "2.1.0-unstable.3" },
    releases,
  };
  routes.set("/releases/index.json", signDocument(doc, key.privateKey));
}

function defaultReleases() {
  return [release("2.0.1", "stable"), release("2.0.2", "stable"), release("2.1.0-unstable.3", "unstable")];
}

function run(args, env = {}) {
  return new Promise((resolve) => {
    execFile(
      lus,
      args,
      {
        env: {
          PATH: process.env.PATH,
          HOME: home,
          LUS_HOME: home,
          LUS_RELEASE_URL: `${srv.base}/releases/`,
          LUS_RELEASE_KEY: root.public,
          ...env,
        },
      },
      (err, stdout, stderr) => resolve({ status: err ? (err.code ?? 1) : 0, stdout, stderr }),
    );
  });
}

async function json(args, env) {
  const r = await run([...args, "--json"], env);
  return { ...r, value: JSON.parse(r.stdout) };
}

before(async () => {
  home = await mkdtemp(path.join(os.tmpdir(), "lus-version-"));
  srv = await serve(routes);
  // Every release archive holds the binary under test, so `lus +REQUEST`
  // runs a real lus.
  const binary = readFileSync(lus);
  archive = gzipSync(
    ustar([
      { name: "bin/", dir: true },
      { name: `bin/${exe}`, data: binary, mode: 0o755 },
      { name: "LICENSE", data: "license\n" },
    ]),
  );
  routes.set("/releases/keys.json", keyList(root, [signing]));
  for (const v of ["2.0.1", "2.0.2", "2.1.0-unstable.3"]) routes.set(`/a/${v}.tar.gz`, archive);
  setIndex({ releases: defaultReleases() });
});

after(async () => {
  srv.server.close();
  await rm(home, { recursive: true, force: true });
});

test("version prints the running version", async () => {
  const r = await json(["version"]);
  assert.equal(r.status, 0);
  assert.equal(r.value.schema, 1);
  assert.match(r.value.version, /^\d+\.\d+\.\d+/);
  const t = await run(["version"]);
  assert.match(t.stdout, /^Lus \d/);
});

test("list starts empty", async () => {
  const r = await json(["version", "list"]);
  assert.deepEqual(r.value, { schema: 1, default: null, versions: [] });
});

test("which without a default exits 3", async () => {
  const r = await json(["version", "which"]);
  assert.equal(r.status, 3);
  assert.equal(r.value.error.code, "not-installed");
});

test("install a line selects its highest stable release", async () => {
  const r = await json(["version", "install", "2.0"]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.value.version, "2.0.2");
  assert.equal(r.value.already, false);
  assert.equal(r.value.path, path.join(home, "versions", "2.0.2", "bin", exe));
  assert.equal(readFileSync(path.join(home, "versions", "2.0.2", "channel"), "utf8"), "stable\n");
  // The first installed version becomes the default.
  assert.equal(readFileSync(path.join(home, "default"), "utf8"), "2.0.2\n");
  if (!windows) assert.equal(readlinkSync(path.join(home, "bin", exe)), path.join("..", "versions", "2.0.2", "bin", exe));
  assert.equal(readFileSync(path.join(home, "index", "seen"), "utf8"), "2026-06-02T00:00:00Z");
});

test("install of an installed version reports already", async () => {
  const r = await json(["version", "install", "2.0.2"]);
  assert.equal(r.status, 0);
  assert.equal(r.value.already, true);
});

test("install a channel", async () => {
  const r = await json(["version", "install", "unstable"]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.value.version, "2.1.0-unstable.3");
  const l = await json(["version", "list"]);
  assert.deepEqual(
    l.value.versions.map((v) => [v.version, v.channel, v.default]),
    [
      ["2.0.2", "stable", true],
      ["2.1.0-unstable.3", "unstable", false],
    ],
  );
  assert.equal(l.value.default, "2.0.2");
});

test("which prints a path", async () => {
  const t = await run(["version", "which", "unstable"]);
  assert.equal(t.status, 0);
  assert.equal(t.stdout, path.join(home, "versions", "2.1.0-unstable.3", "bin", exe) + "\n");
  const d = await json(["version", "which"]);
  assert.equal(d.value.version, "2.0.2");
});

test("use", async () => {
  const missing = await json(["version", "use", "2.0.1"]);
  assert.equal(missing.status, 3);
  assert.equal(missing.value.error.code, "not-installed");
  assert.equal((await json(["version", "install", "2.0.1"])).status, 0);
  const r = await json(["version", "use", "2.0.1"]);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.value, { schema: 1, version: "2.0.1", path: path.join(home, "bin", exe), previous: "2.0.2" });
  assert.equal(readFileSync(path.join(home, "default"), "utf8"), "2.0.1\n");
});

test("use warns when another lus comes first on PATH", async () => {
  const r = await run(["version", "use", "2.0.1"], { PATH: path.dirname(lus) });
  assert.equal(r.status, 0);
  assert.match(r.stderr, /comes first on PATH/);
  const quiet = await run(["version", "use", "2.0.1"], { PATH: path.join(home, "bin") });
  assert.doesNotMatch(quiet.stderr, /comes first on PATH/);
});

test("remove", async () => {
  const inUse = await json(["version", "remove", "2.0.1"]);
  assert.equal(inUse.status, 5);
  assert.equal(inUse.value.error.code, "in-use");
  const r = await json(["version", "remove", "2.0.2"]);
  assert.deepEqual(r.value, { schema: 1, version: "2.0.2", removed: true });
  assert.equal(existsSync(path.join(home, "versions", "2.0.2")), false);
  assert.equal((await json(["version", "remove", "9.9.9"])).status, 3);
  assert.equal((await json(["version", "remove", "2.0"])).status, 2);
});

test("list --remote", async () => {
  const r = await json(["version", "list", "--remote"]);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(
    r.value.versions.map((v) => [v.version, v.installed]),
    [
      ["2.0.1", true],
      ["2.0.2", false],
    ],
  );
  const u = await json(["version", "list", "--remote", "unstable"]);
  assert.deepEqual(u.value.versions.map((v) => v.version), ["2.1.0-unstable.3"]);
});

test("+REQUEST runs an installed version", async () => {
  const r = await run(["+2.0", "-v"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr + r.stdout, /Lus \d/);
  const code = await run(["+unstable", "-e", "os.exit(7)"]);
  assert.equal(code.status, 7);
  assert.equal((await run(["+9"])).status, 3);
  assert.equal((await run(["+two"])).status, 2);
});

test("usage errors exit 2", async () => {
  assert.equal((await json(["version", "install"])).status, 2);
  const r = await json(["version", "install", "two"]);
  assert.equal(r.status, 2);
  assert.equal(r.value.error.code, "usage");
  assert.equal((await run(["version", "frobnicate"])).status, 2);
});

test("a release absent from the index exits 3", async () => {
  const r = await json(["version", "install", "3.0"]);
  assert.equal(r.status, 3);
  assert.equal(r.value.error.code, "not-found");
});

test("a tampered archive installs nothing", async () => {
  const bad = Buffer.from(archive);
  bad[bad.length - 20] ^= 0xff;
  setIndex({ releases: [...defaultReleases(), release("2.0.3", "stable")] });
  routes.set("/a/2.0.3.tar.gz", bad);
  const r = await json(["version", "install", "2.0.3"]);
  assert.equal(r.status, 4);
  assert.equal(r.value.error.code, "verify");
  assert.equal(existsSync(path.join(home, "versions", "2.0.3")), false);
});

test("an index with a bad signature is refused", async () => {
  setIndex({ releases: defaultReleases(), key: { ...keyPair(), id: "lus-test-1" } });
  const r = await json(["version", "install", "2.0.2"]);
  assert.equal(r.status, 4);
  assert.match(r.value.error.message, /does not verify/);
});

test("a replayed older index is refused", async () => {
  setIndex({ releases: defaultReleases(), signed: "2026-05-01T00:00:00Z" });
  const r = await json(["version", "install", "2.0.2"]);
  assert.equal(r.status, 4);
  assert.match(r.value.error.message, /replay/);
  setIndex({ releases: defaultReleases() });
});

test("LUS_RELEASE_KEY applies only to a loopback release URL", async () => {
  const r = await json(["version", "install", "2.0.2"], { LUS_RELEASE_URL: "https://releases.invalid/" });
  // The test key is ignored, so lus falls back to the release root. A build
  // without a root trusts no key, and a build with one fetches keys.json.
  assert.notEqual(r.status, 0);
  assert.match(r.value.error.message, /trusts no release key|keys\.json/);
});

test("an index that tools/release-index.mjs builds installs", async () => {
  const tag = "v2.0.4";
  const name = `lus-${tag}-${target()}.${windows ? "zip" : "tar.gz"}`;
  routes.set(`/gh/${name}`, archive);
  let payload = addRelease(undefined, {
    tag: "v2.0.2",
    sums: `${sha256(archive)}  lus-v2.0.2-${target()}.tar.gz\n`,
    assets: [{ name: `lus-v2.0.2-${target()}.tar.gz`, size: archive.length }],
    base: `${srv.base}/gh`,
    now: new Date("2026-06-03T00:00:00Z"),
  });
  payload = addRelease(payload, {
    tag,
    sums: `${sha256(archive)}  ${name}\n${sha256("x")}  lus.wasm\n`,
    assets: [{ name, size: archive.length }],
    base: `${srv.base}/gh`,
    now: new Date("2026-06-03T00:00:00Z"),
  });
  assert.equal(payload.signed, "2026-06-03T00:00:01Z");
  assert.deepEqual(payload.channels, { stable: "2.0.4" });
  routes.set("/releases/index.json", signDocument({ ...payload, key: signing.id }, signing.privateKey));
  const r = await json(["version", "install", "stable"]);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.equal(r.value.version, "2.0.4");
  setIndex({ releases: defaultReleases(), signed: "2026-06-04T00:00:00Z" });
});

test("the layout of the home", async () => {
  const names = (await readFile(path.join(home, "default"), "utf8")).trim();
  assert.equal(names, "2.0.1");
  for (const p of ["bin", "versions", "index/seen", "lock", "default"]) assert.ok(existsSync(path.join(home, p)), p);
});
