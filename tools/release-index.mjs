#!/usr/bin/env node
// Builds and signs the files behind https://lus.dev/releases/, which
// `lus version` reads (spec/tools/version.md).
//
//   node tools/release-index.mjs keygen
//       Prints a new Ed25519 key as JSON: its seed and its public key, in
//       base64. Keep the seed of the root key offline.
//
//   node tools/release-index.mjs keylist --root-seed FILE --out keys.json
//       --key ID=PUBLIC[@NOT_BEFORE..NOT_AFTER] ...
//       Writes the key list, signed by the root key whose seed FILE holds.
//
//   node tools/release-index.mjs index --tag vX.Y.Z --sums SHA256SUMS
//       --assets assets.json --base URL [--previous index.json] --out index.json
//       Adds the release TAG to the previous index and signs the result
//       with the signing key in LUS_RELEASE_SIGNING_SEED, whose identifier
//       is LUS_RELEASE_SIGNING_KEY_ID. assets.json is the output of
//       `gh release view TAG --json assets`, which gives the sizes.

import { readFileSync, writeFileSync } from "node:fs";
import { generate, keyList, privateKeyFromSeed, rfc3339, signDocument } from "./signed-doc.mjs";

export const targets = [
  "aarch64-macos",
  "x86_64-macos",
  "aarch64-linux-musl",
  "x86_64-linux-musl",
  "arm-linux-musleabihf",
  "riscv64-linux-musl",
  "loongarch64-linux-musl",
  "powerpc64le-linux-musl",
  "s390x-linux-musl",
  "x86_64-freebsd",
  "aarch64-freebsd",
  "x86_64-windows",
  "aarch64-windows",
];

function args(argv) {
  const out = { _: [], key: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      out._.push(a);
      continue;
    }
    const name = a.slice(2);
    const value = argv[++i];
    if (value === undefined) throw new Error(`${a} needs a value`);
    if (name === "key") out.key.push(value);
    else out[name] = value;
  }
  return out;
}

// Orders versions as Semantic Versioning 2.0.0 does.
export function compareVersions(a, b) {
  const split = (v) => {
    const [core, pre = ""] = v.split(/-(.*)/s);
    return { nums: core.split(".").map(Number), pre };
  };
  const x = split(a);
  const y = split(b);
  for (let i = 0; i < 3; i++) if (x.nums[i] !== y.nums[i]) return x.nums[i] - y.nums[i];
  if (x.pre === y.pre) return 0;
  if (x.pre === "") return 1;
  if (y.pre === "") return -1;
  const ia = x.pre.split(".");
  const ib = y.pre.split(".");
  for (let i = 0; i < Math.max(ia.length, ib.length); i++) {
    if (ia[i] === undefined) return -1;
    if (ib[i] === undefined) return 1;
    const na = /^\d+$/.test(ia[i]);
    const nb = /^\d+$/.test(ib[i]);
    if (na && nb && Number(ia[i]) !== Number(ib[i])) return Number(ia[i]) - Number(ib[i]);
    if (na !== nb) return na ? -1 : 1;
    if (ia[i] !== ib[i]) return ia[i] < ib[i] ? -1 : 1;
  }
  return 0;
}

// Adds the release `tag` to `previous` and returns the new index payload.
export function addRelease(previous, { tag, sums, assets, base, now }) {
  const version = tag.replace(/^v/, "");
  const channel = version.includes("-unstable") ? "unstable" : "stable";
  const digests = new Map();
  for (const line of sums.split("\n")) {
    const m = line.match(/^([0-9a-f]{64})\s+\*?(.+)$/);
    if (m) digests.set(m[2], m[1]);
  }
  const sizes = new Map(assets.map((a) => [a.name, a.size]));
  const entry = { version, channel, published: rfc3339(now), assets: {} };
  for (const t of targets) {
    for (const ext of ["tar.gz", "zip"]) {
      const name = `lus-${tag}-${t}.${ext}`;
      if (!digests.has(name)) continue;
      if (!sizes.has(name)) throw new Error(`no size for ${name}`);
      entry.assets[t] = { url: `${base.replace(/\/$/, "")}/${name}`, sha256: digests.get(name), size: sizes.get(name) };
    }
  }
  if (Object.keys(entry.assets).length === 0) throw new Error(`SHA256SUMS lists no archive of ${tag}`);
  const releases = (previous?.releases ?? []).filter((r) => r.version !== version);
  releases.push(entry);
  releases.sort((a, b) => compareVersions(a.version, b.version));
  const channels = {};
  for (const r of releases) channels[r.channel] = r.version;
  // A newer index must never carry an older time, or clients that saw the
  // previous one refuse it.
  let signed = now;
  if (previous?.signed) {
    const prev = new Date(previous.signed);
    if (signed <= prev) signed = new Date(prev.getTime() + 1000);
  }
  return { schema: 1, signed: rfc3339(signed), channels, releases };
}

function main(argv) {
  const a = args(argv);
  const cmd = a._[0];
  if (cmd === "keygen") {
    console.log(JSON.stringify(generate()));
    return;
  }
  if (cmd === "keylist") {
    const root = privateKeyFromSeed(readFileSync(a["root-seed"], "utf8").trim());
    const keys = a.key.map((spec) => {
      const m = spec.match(/^([^=]+)=([A-Za-z0-9+/=]+)(?:@([^.]+)\.\.(.+))?$/);
      if (!m) throw new Error(`malformed --key ${spec}`);
      return { id: m[1], public: m[2], not_before: m[3] ?? "2026-01-01T00:00:00Z", not_after: m[4] ?? "2036-01-01T00:00:00Z" };
    });
    writeFileSync(a.out, keyList(root, keys, rfc3339(new Date())));
    return;
  }
  if (cmd === "index") {
    const seed = process.env.LUS_RELEASE_SIGNING_SEED;
    const id = process.env.LUS_RELEASE_SIGNING_KEY_ID;
    if (!seed || !id) throw new Error("LUS_RELEASE_SIGNING_SEED and LUS_RELEASE_SIGNING_KEY_ID must be set");
    let previous;
    if (a.previous) {
      try {
        previous = JSON.parse(readFileSync(a.previous, "utf8"));
      } catch {
        previous = undefined;
      }
    }
    const payload = addRelease(previous, {
      tag: a.tag,
      sums: readFileSync(a.sums, "utf8"),
      assets: JSON.parse(readFileSync(a.assets, "utf8")).assets,
      base: a.base,
      now: new Date(),
    });
    writeFileSync(a.out, signDocument({ ...payload, key: id }, privateKeyFromSeed(seed)));
    return;
  }
  throw new Error("usage: release-index.mjs keygen | keylist ... | index ...");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`release-index: ${e.message}`);
    process.exit(1);
  }
}
