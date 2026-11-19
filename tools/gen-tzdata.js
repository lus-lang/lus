#!/usr/bin/env node
// Regenerates the embedded IANA tzdata of the `time` module:
// runtime/src/lib/data/tzdata.zst and runtime/src/lib/data/tzdata.version.
//
// Usage: node tools/gen-tzdata.js [zoneinfo_dir]
//
// With no argument the script downloads the pinned IANA data and code
// releases, verifies their SHA-256 digests, and builds the TZif files with
// the release's own `zic` (this needs curl, tar, make, and a C compiler).
// Passing an existing zoneinfo directory regenerates offline from it. The
// output then carries whatever release that directory holds. The zstd CLI
// is required in both cases.
//
// The container is a flat index (all integers little endian):
//   "LTZ1"                       magic
//   u8  version_len, version     for example "2026c"
//   u32 zone_count
//   repeat zone_count, sorted by name:
//     u16 name_len, name         for example "America/New_York"
//     u32 tzif_len, tzif bytes   the RFC 8536 TZif file, copied verbatim
// The whole container is compressed with `zstd -19`. The runtime
// decompresses it on first zone access (see runtime/src/lib/timecore.zig).
// tzdata is in the public domain.

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const {execFileSync} = require("child_process");

const ROOT = path.join(__dirname, "..");
const DATA_DIR = path.join(ROOT, "runtime", "src", "lib", "data");

const TZDATA_VERSION = "2026c";
const TZDATA_SHA256 = "e4a178a4477f3d0ea77cc31828ff72aa38feff8d61aa13e7e99e142e9d902be4";
const TZCODE_SHA256 = "b1cffc3ace4c4c7cd0efba2f7add86ec3d0b79da48bcf03582671fd3c8feace8";
const RELEASES = "https://data.iana.org/time-zones/releases";

function requireTool(tool) {
  try {
    execFileSync("sh", ["-c", `command -v ${tool}`], {stdio: "ignore"});
  } catch (_) {
    console.error(`error: ${tool} is required`);
    process.exit(1);
  }
}

function download(url, file, sha256) {
  execFileSync("curl", ["-fsSL", "--max-time", "120", url, "-o", file], {stdio: "inherit"});
  const digest = crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  if (digest !== sha256) {
    console.error(`error: ${url} has SHA-256 ${digest}, expected ${sha256}`);
    process.exit(1);
  }
}

// Builds the pinned release and returns its zoneinfo directory.
function buildRelease(tmp) {
  for (const tool of ["curl", "tar", "make"]) requireTool(tool);
  const data = path.join(tmp, `tzdata${TZDATA_VERSION}.tar.gz`);
  const code = path.join(tmp, `tzcode${TZDATA_VERSION}.tar.gz`);
  download(`${RELEASES}/tzdata${TZDATA_VERSION}.tar.gz`, data, TZDATA_SHA256);
  download(`${RELEASES}/tzcode${TZDATA_VERSION}.tar.gz`, code, TZCODE_SHA256);
  const src = path.join(tmp, "src");
  fs.mkdirSync(src);
  execFileSync("tar", ["-C", src, "-xf", data]);
  execFileSync("tar", ["-C", src, "-xf", code]);
  execFileSync("make", ["-C", src, `TOPDIR=${path.join(tmp, "out")}`, "install"], {
    stdio: ["ignore", "ignore", "inherit"],
  });
  return path.join(tmp, "out", "usr", "share", "zoneinfo");
}

// Collects every TZif file under the tree. The right/ (leap second) and
// posix/ variants duplicate the main zones and are skipped.
function collect(dir, root, out) {
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(root, full);
    if (rel.startsWith("right" + path.sep) || rel.startsWith("posix" + path.sep)) continue;
    if (entry.isDirectory()) {
      collect(full, root, out);
    } else if (entry.isFile()) {
      const data = fs.readFileSync(full);
      if (data.length >= 4 && data.toString("latin1", 0, 4) === "TZif") {
        out.push({name: rel.split(path.sep).join("/"), data});
      }
    }
  }
}

// tzdata.zi carries "# version 2026c" on its first line.
function detectVersion(root) {
  try {
    const zi = fs.readFileSync(path.join(root, "tzdata.zi"), "latin1");
    const m = zi.match(/#\s*version\s+(\S+)/);
    if (m) return m[1];
  } catch (_) {}
  try {
    return fs.readFileSync(path.join(root, "+VERSION"), "latin1").trim();
  } catch (_) {}
  return "unknown";
}

requireTool("zstd");
let tmp = null;
let zoneinfo = process.argv[2];
if (!zoneinfo) {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "lus-tzdata-"));
  zoneinfo = buildRelease(tmp);
}
try {
  if (!fs.existsSync(zoneinfo) || !fs.statSync(zoneinfo).isDirectory()) {
    console.error(`error: zoneinfo directory not found: ${zoneinfo}`);
    process.exit(1);
  }

  const zones = [];
  collect(zoneinfo, zoneinfo, zones);
  zones.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const version = detectVersion(zoneinfo);

  const parts = [Buffer.from("LTZ1", "latin1")];
  const vbuf = Buffer.from(version, "latin1");
  parts.push(Buffer.from([vbuf.length]), vbuf);
  const count = Buffer.alloc(4);
  count.writeUInt32LE(zones.length, 0);
  parts.push(count);
  for (const z of zones) {
    const nb = Buffer.from(z.name, "latin1");
    const nl = Buffer.alloc(2);
    nl.writeUInt16LE(nb.length, 0);
    const dl = Buffer.alloc(4);
    dl.writeUInt32LE(z.data.length, 0);
    parts.push(nl, nb, dl, z.data);
  }
  const raw = Buffer.concat(parts);
  const compressed = execFileSync("zstd", ["-19", "-c"], {input: raw, maxBuffer: 1 << 30});

  fs.writeFileSync(path.join(DATA_DIR, "tzdata.zst"), compressed);
  fs.writeFileSync(path.join(DATA_DIR, "tzdata.version"), version);
  console.log(
    `Wrote runtime/src/lib/data: tzdata ${version}, ${zones.length} zones, ` +
      `${raw.length} -> ${compressed.length} bytes (zstd -19).`
  );
} finally {
  if (tmp) fs.rmSync(tmp, {recursive: true, force: true});
}
