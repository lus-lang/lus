// Pins remote requires (spec/tools/atmosphere.md, spec/design/modules.md
// sections 3 to 5): an atmosphere server and a generic server on loopback,
// the checks of release documents and bundles, the module cache, fetching
// before the run, and the permissions that a remote require needs.
//
//   node tests/remote/remote.test.mjs runtime/zig-out/bin/lus

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { keyList, keyPair, serve, sha256, signDocument, ustar } from "../lib/release.mjs";

const lus = path.resolve(process.argv[2] ?? process.env.LUS_BIN ?? "runtime/zig-out/bin/lus");
const root = keyPair();
const signing = { ...keyPair(), id: "atmos-test-1" };
const routes = new Map();
const genericRoutes = new Map();
let srv;
let gsrv;
let home;
let work;
let base;

const datesFiles = {
  "dates.lus": [
    "--- Dates for tests.",
    "--- @package dates",
    "--- @version 1.4.1",
    "--- @lus 2.0",
    "--- @license 0BSD",
    "--- @includes strings https://atmosp.here/2.0/strings.lus 1.0.0",
    "",
    'local zones = require("dates.zones")',
    'local strings = require("strings")',
    'local s = require("string")',
    'return { zone = zones.name, shout = strings.up("hi"), lib = s == string }',
    "",
  ].join("\n"),
  "dates/zones.lus": 'return { name = "UTC" }\n',
  "strings.lus": "return { up = function(x) return x:upper() end }\n",
  LICENSE: "0BSD\n",
};

function bundleOf(files, extra = []) {
  const entries = [];
  const dirs = new Set();
  for (const name of Object.keys(files)) {
    const parts = name.split("/");
    for (let i = 1; i < parts.length; i++) dirs.add(parts.slice(0, i).join("/") + "/");
  }
  for (const d of dirs) entries.push({ name: d, dir: true });
  for (const [name, data] of Object.entries(files)) entries.push({ name, data });
  return zstdCompressSync(ustar([...entries, ...extra]));
}

// Publishes a release of `dates` at the line URL and its pinned URL.
function publish({ flags = [], version = "1.4.1", lus: line = "2.0", lusMin = "2.0.0", signed = "2026-06-02T00:00:00Z", files = datesFiles, extra = [], tamper = false, key = signing, yanked = false, deprecated = null, name = "dates", path: urlPath = `/2.0/${name}.lus` } = {}) {
  const bundle = bundleOf(files, extra);
  const sha = sha256(bundle);
  const served = tamper ? Buffer.concat([bundle, Buffer.from([0])]) : bundle;
  routes.set(`/b/${sha}.tar.zst`, { body: served, headers: { "content-type": "application/zstd" } });
  const doc = signDocument(
    {
      bundle: `${base}/b/${sha}.tar.zst`,
      commit: "0".repeat(40),
      deprecated,
      files: Object.fromEntries(Object.entries(files).map(([n, d]) => [n, sha256(Buffer.from(d))])),
      flags,
      key: key.id,
      lus: line,
      lus_min: lusMin,
      main: `${name}.lus`,
      name,
      permissions: [],
      requires: [],
      sha256: sha,
      signed,
      size: bundle.length,
      version,
      yanked,
    },
    key.privateKey,
  );
  const answer = {
    body: doc,
    headers: { "content-type": "application/vnd.atmos.release+json", vary: "Accept", "cache-control": "max-age=300" },
  };
  routes.set(urlPath, answer);
  routes.set(urlPath.replace(/\.lus$/, `@${version}.lus`), answer);
}

function run(args, { env = {}, cwd = work } = {}) {
  return new Promise((resolve) => {
    execFile(lus, args, { cwd, env: { PATH: process.env.PATH, HOME: home, LUS_HOME: home, ...env } }, (err, stdout, stderr) =>
      resolve({ status: err ? (err.code ?? 1) : 0, stdout, stderr }),
    );
  });
}

async function script(name, body) {
  const file = path.join(work, name);
  await writeFile(file, body);
  return file;
}

function requests(prefix) {
  return srv.log.filter((r) => r.url.startsWith(prefix)).length;
}

before(async () => {
  home = await mkdtemp(path.join(os.tmpdir(), "lus-remote-home-"));
  work = await mkdtemp(path.join(os.tmpdir(), "lus-remote-work-"));
  srv = await serve(routes);
  base = srv.base;
  routes.set("/.well-known/atmos-keys.json", keyList(root, [signing], "2026-06-01T00:00:00Z", { root: root.public }));
  publish();
  // A generic server runs on its own port, which is another host to lus.
  gsrv = await serve(genericRoutes);
  genericRoutes.set("/g/hello.lus", { body: 'local util = require("util")\nreturn { msg = "hello " .. util.name }\n', headers: { "content-type": "text/plain" } });
  genericRoutes.set("/g/util.lus", { body: 'return { name = "util" }\n', headers: { "content-type": "text/plain" } });
});

after(async () => {
  srv.server.close();
  gsrv.server.close();
  await rm(home, { recursive: true, force: true });
  await rm(work, { recursive: true, force: true });
});

test("an atmosphere package loads with its modules and copied dependencies", async () => {
  const f = await script(
    "dates_main.lus",
    `pledge("load", "network:http=127.0.0.1:*")
local dates = require("${base}/2.0/dates.lus")
print(dates.zone, dates.shout, dates.lib)
print(require("${base}/2.0/dates.lus") == dates)
`,
  );
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "UTC\tHI\ttrue\ntrue\n");
  assert.doesNotMatch(r.stderr, /warning/);
});

test("the module cache holds the documented layout", async () => {
  const cache = path.join(home, "cache");
  const host = `127.0.0.1_${new URL(base).port}`;
  const hostRecord = JSON.parse(readFileSync(path.join(cache, "hosts", `${host}.json`), "utf8"));
  assert.equal(hostRecord.kind, "atmosphere");
  assert.equal(hostRecord.root, root.public);
  assert.ok(existsSync(path.join(cache, "keys", `${host}.json`)));
  const modules = readdirSync(path.join(cache, "modules"));
  assert.ok(modules.every((m) => /^[0-9a-f]{32}$/.test(m)));
  const urls = modules.map((m) => readFileSync(path.join(cache, "modules", m, "url"), "utf8"));
  assert.ok(urls.includes(`${base}/2.0/dates.lus`));
  const releases = readdirSync(path.join(cache, "releases"));
  assert.ok(releases.length >= 1 && releases.every((r) => /^[0-9a-f]{64}\.json$/.test(r)));
  const bundles = readdirSync(path.join(cache, "bundles")).filter((b) => !b.includes("."));
  assert.ok(bundles.length >= 1);
  assert.ok(existsSync(path.join(cache, "bundles", bundles[0], "dates", "zones.lus")));
});

test("a fresh cache entry needs no request", async () => {
  const f = path.join(work, "dates_main.lus");
  const before = requests("/2.0/dates.lus");
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(requests("/2.0/dates.lus"), before);
});

test("--reload revalidates and --offline uses the cache", async () => {
  const f = path.join(work, "dates_main.lus");
  const before = requests("/2.0/dates.lus");
  assert.equal((await run(["--reload", f])).status, 0);
  assert.equal(requests("/2.0/dates.lus"), before + 1);
  const off = await run(["--offline", f]);
  assert.equal(off.status, 0, off.stderr);
  assert.equal(requests("/2.0/dates.lus"), before + 1);
  const g = await script("missing.lus", `pledge("load", "network:http=127.0.0.1:*")\nrequire("${base}/2.0/nothing.lus")\n`);
  const miss = await run(["--offline", g]);
  assert.notEqual(miss.status, 0);
  assert.match(miss.stderr, /--offline forbids fetching it/);
});

test("a literal require fetches before the run, a computed one warns", async () => {
  await rm(path.join(home, "cache"), { recursive: true, force: true });
  const f = await script(
    "order.lus",
    `pledge("load", "network:http=127.0.0.1:*")
print("start")
local dates = require("${base}/2.0/dates.lus")
local url = "${gsrv.base}" .. "/g/util.lus"
local util = require(url)
print(dates.zone, util.name)
`,
  );
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "start\nUTC\tutil\n");
  assert.doesNotMatch(r.stderr, /dates\.lus during execution/);
  assert.match(r.stderr, /order\.lus:5: fetched .*\/g\/util\.lus during execution/);
});

test("a generic server serves files and their relative requires", async () => {
  const f = await script("generic.lus", `pledge("load", "network:http=127.0.0.1:*")\nprint(require("${gsrv.base}/g/hello.lus").msg)\n`);
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "hello util\n");
});

test("every remote require needs load and network:http for its URL", async () => {
  const none = await script("noperm.lus", `print(catch require("${base}/2.0/dates.lus"))\n`);
  const r1 = await run([none]);
  assert.match(r1.stdout, /permission "network:http" denied/);
  const other = await script("otherhost.lus", `pledge("load", "network:http=example.com")\nprint(catch require("${base}/2.0/dates.lus"))\n`);
  const r2 = await run([other]);
  assert.match(r2.stdout, /permission "network:http" denied/);
  const noload = await script("noload.lus", `pledge("network:http")\nprint(catch require("${base}/2.0/dates.lus"))\n`);
  const r3 = await run([noload]);
  assert.match(r3.stdout, /permission "load" denied/);
});

test("-P without network fetches nothing before the run", async () => {
  await rm(path.join(home, "cache"), { recursive: true, force: true });
  const f = path.join(work, "dates_main.lus");
  const before = requests("/");
  const r = await run(["-P", "load", f]);
  assert.notEqual(r.status, 0);
  assert.equal(requests("/"), before);
});

test("a module of a package wins over a program module of the same name", async () => {
  const f = await script(
    "shadow.lus",
    `pledge("load", "network:http=127.0.0.1:*")
package.loaded.strings = { up = function() return "program" end }
print(require("${base}/2.0/dates.lus").shout)
`,
  );
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "HI\n");
});

function freshCheck() {
  return rm(path.join(home, "cache"), { recursive: true, force: true });
}

async function expectFailure(pattern, url = `${base}/2.0/dates.lus`) {
  const f = await script("fail.lus", `pledge("load", "network:http=127.0.0.1:*")\nlocal ok, e = catch require("${url}")\nprint(ok, e)\n`);
  const r = await run(["--reload", f]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, pattern);
}

test("a package for a newer line or release is refused", async () => {
  await freshCheck();
  publish({ path: "/2.1/dates.lus", lus: "2.1" });
  await expectFailure(/needs Lus 2\.1, this is Lus/, `${base}/2.1/dates.lus`);
  publish({ path: "/2.0/late.lus", name: "late", lusMin: "2.0.9", files: { "late.lus": "return 1\n" } });
  await expectFailure(/needs Lus 2\.0\.9/, `${base}/2.0/late.lus`);
});

test("a release document with a bad signature is refused", async () => {
  await freshCheck();
  publish({ key: { ...keyPair(), id: "atmos-test-1" } });
  await expectFailure(/does not verify/);
  publish();
});

test("a bundle that does not match its digest is refused", async () => {
  await freshCheck();
  publish({ tamper: true });
  await expectFailure(/bundle of .* has \d+ bytes|does not match its SHA-256 digest/);
  publish();
});

test("a bundle with a link or an unsafe path is refused", async () => {
  await freshCheck();
  publish({ extra: [{ name: "evil", type: "2", link: "/etc/passwd" }] });
  await expectFailure(/not a regular file or a directory/);
  await freshCheck();
  publish({ extra: [{ name: "../escape.lus", data: "x" }] });
  await expectFailure(/unsafe path/);
  publish();
});

test("a line URL accepts only patch releases and never an older document", async () => {
  await freshCheck();
  publish({ version: "1.4.1", signed: "2026-06-02T00:00:00Z" });
  await expectFailure(/^true/);
  publish({ version: "1.5.0", signed: "2026-06-03T00:00:00Z" });
  await expectFailure(/accepts only patch releases/);
  publish({ version: "1.4.2", signed: "2026-06-01T00:00:00Z" });
  await expectFailure(/older than one accepted before/);
  // A withdrawn release moves the line back to an older patch, signed anew.
  publish({ version: "1.4.0", signed: "2026-06-04T00:00:00Z" });
  await expectFailure(/^true/);
  publish();
});

test("a yanked or deprecated release warns once", async () => {
  await freshCheck();
  publish({ yanked: true, deprecated: "use dates2" });
  const f = await script(
    "yanked.lus",
    `pledge("load", "network:http=127.0.0.1:*")\nrequire("${base}/2.0/dates@1.4.1.lus")\nprint("ok")\n`,
  );
  const r = await run([f]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stderr.match(/withdrew/g)?.length, 1, r.stderr);
  assert.equal(r.stderr.match(/is deprecated: use dates2/g)?.length, 1, r.stderr);
  publish();
});

test("an atmosphere host that answers with a plain file is refused", async () => {
  await freshCheck();
  await expectFailure(/^true/);
  routes.set("/2.0/dates.lus", { body: "return {}\n", headers: { "content-type": "text/plain" } });
  await expectFailure(/may have been tampered with/);
  publish();
});

test("an unknown package reports the server's message", async () => {
  await expectFailure(/no route|not found/, `${base}/2.0/nothing.lus`);
});

test("a package reads only its own flags, with declared defaults", async () => {
  publish({
    name: "flagged",
    path: "/2.0/flagged.lus",
    flags: [
      { name: "mode", type: "string", default: "fast" },
      { name: "level", type: "number", default: 1 },
    ],
    files: {
      "flagged.lus": [
        "--- @package flagged",
        "--- @includes dep https://atmosp.here/2.0/dep.lus 1.0.0",
        "",
        'local dep = require("dep")',
        "return { mode = flags.mode, level = flags.level, prog = flags.prog, dep = dep.level }",
        "",
      ].join("\n"),
      "dep.lus": "return { level = flags.level }\n",
    },
  });
  const f = await script(
    "flags.lus",
    `pledge("load", "network:http=127.0.0.1:*")
local m = require("${base}/2.0/flagged.lus")
print(m.mode, m.level, m.prog, m.dep, flags.prog)
`,
  );
  const plain = await run([f]);
  assert.equal(plain.status, 0, plain.stderr);
  assert.equal(plain.stdout, "fast\t1\tnil\tnil\tnil\n");
  const set = await run(["-F", "flagged.mode=slow", "-F", "dep.level=3", "-F", "prog=yes", f]);
  assert.equal(set.status, 0, set.stderr);
  assert.equal(set.stdout, "slow\t1\tnil\t3\tyes\n");
});

test("lus build bundles remote modules, which then load with no network", async () => {
  await freshCheck();
  publish();
  const f = await script(
    "built.lus",
    `local dates = require("${base}/2.0/dates.lus")
local hello = require("${gsrv.base}/g/hello.lus")
print(dates.zone, dates.shout, hello.msg)
`,
  );
  const out = path.join(work, "built-app");
  const b = await run(["build", "-o", out, f]);
  assert.equal(b.status, 0, b.stderr);
  const empty = await mkdtemp(path.join(os.tmpdir(), "lus-remote-empty-"));
  const before = requests("/");
  const r = await new Promise((resolve) =>
    execFile(out, [], { env: { PATH: process.env.PATH, HOME: empty, LUS_HOME: empty } }, (err, stdout, stderr) =>
      resolve({ status: err ? (err.code ?? 1) : 0, stdout, stderr }),
    ),
  );
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "UTC\tHI\thello util\n");
  assert.equal(requests("/"), before);
  assert.equal(existsSync(path.join(empty, "cache")), false);
  await rm(empty, { recursive: true, force: true });
});

test("lus test loads remote modules as lus does", async () => {
  await freshCheck();
  publish();
  const f = await script(
    "remote_test.lus",
    `pledge("load", "network:http=127.0.0.1:*")

local function loads_a_package_test()
    local dates = require("${base}/2.0/dates.lus")
    assert(dates.zone == "UTC")
end
`,
  );
  const r = await run(["test", f]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /1 passed, 0 failed/);
  assert.doesNotMatch(r.stdout + r.stderr, /unavailable/);
});
