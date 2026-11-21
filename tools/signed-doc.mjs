// Signed documents of the Lus release index and of atmosphere
// (spec/tools/version.md, spec/tools/atmosphere.md): canonical JSON with
// a `key`, a `signed` time, and a base64 Ed25519 `signature` of the
// canonical JSON of the document without its `signature` field.

import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from "node:crypto";

// Canonical JSON: keys sorted by byte value, no insignificant whitespace.
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

const pkcs8Prefix = Buffer.from("302e020100300506032b657004220420", "hex");

// The private key of a 32-byte seed given in base64.
export function privateKeyFromSeed(seed) {
  const raw = Buffer.from(seed, "base64");
  if (raw.length !== 32) throw new Error("an Ed25519 seed is 32 bytes");
  return createPrivateKey({ key: Buffer.concat([pkcs8Prefix, raw]), format: "der", type: "pkcs8" });
}

// The raw public key of a private key, in base64.
export function publicOf(privateKey) {
  const der = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return der.subarray(der.length - 32).toString("base64");
}

// A new key: its seed and its public key, both in base64.
export function generate() {
  const { privateKey } = generateKeyPairSync("ed25519");
  const der = privateKey.export({ format: "der", type: "pkcs8" });
  return { seed: der.subarray(der.length - 32).toString("base64"), public: publicOf(privateKey) };
}

// Signs `doc` and returns the canonical bytes with the `signature` member
// in its sorted place.
export function signDocument(doc, privateKey) {
  const unsigned = { ...doc };
  delete unsigned.signature;
  const sig = sign(null, Buffer.from(canonical(unsigned)), privateKey).toString("base64");
  return canonical({ ...unsigned, signature: sig });
}

// A key list that the root key signs. Each key is {id, public,
// not_before, not_after}.
export function keyList(rootPrivateKey, keys, signed, extra = {}) {
  return signDocument({ key: "root", signed, keys, ...extra }, rootPrivateKey);
}

// Seconds-precision RFC 3339 time in UTC.
export function rfc3339(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}
