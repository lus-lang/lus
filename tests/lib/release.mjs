// Helpers shared by the tool tests that serve releases and packages to a
// real `lus` process: canonical JSON, Ed25519 signed documents, ustar
// archives, and a loopback HTTP server whose routes a test can change.

import { createHash, generateKeyPairSync } from "node:crypto";
import http from "node:http";
import { canonical, keyList as signedKeyList, publicOf, signDocument } from "../../tools/signed-doc.mjs";

export { canonical, signDocument };

// An Ed25519 key pair with its raw public key in base64.
export function keyPair() {
  const { privateKey } = generateKeyPairSync("ed25519");
  return { privateKey, public: publicOf(privateKey) };
}

// A key list that `root` signs, holding `keys` ({id, public}).
export function keyList(root, keys, signed = "2026-06-01T00:00:00Z", extra = {}) {
  return signedKeyList(
    root.privateKey,
    keys.map((k) => ({
      id: k.id,
      public: k.public,
      not_before: k.not_before ?? "2020-01-01T00:00:00Z",
      not_after: k.not_after ?? "2040-01-01T00:00:00Z",
    })),
    signed,
    extra,
  );
}

export function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

// A ustar archive of `entries`, each {name, data} for a file or {name,
// dir: true}, with an optional `mode` and `type` (a typeflag character).
export function ustar(entries) {
  const blocks = [];
  for (const e of entries) {
    const data = e.dir ? Buffer.alloc(0) : Buffer.from(e.data ?? "");
    const h = Buffer.alloc(512);
    let name = e.name;
    let prefix = "";
    if (Buffer.byteLength(name) > 100) {
      const cut = name.lastIndexOf("/", 155);
      prefix = name.slice(0, cut);
      name = name.slice(cut + 1);
    }
    h.write(name, 0, 100);
    h.write(((e.mode ?? (e.dir ? 0o755 : 0o644)).toString(8).padStart(7, "0")) + "\0", 100);
    h.write("0000000\0", 108);
    h.write("0000000\0", 116);
    h.write(data.length.toString(8).padStart(11, "0") + "\0", 124);
    h.write("00000000000\0", 136);
    h.write("        ", 148);
    h.write(e.type ?? (e.dir ? "5" : "0"), 156);
    if (e.link) h.write(e.link, 157, 100);
    h.write("ustar\0", 257);
    h.write("00", 263);
    h.write(prefix, 345, 155);
    let sum = 0;
    for (const b of h) sum += b;
    h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148);
    blocks.push(h, data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

// A loopback HTTP server. `routes` maps a path to a function of the
// request that returns {status, headers, body}, or to a body.
export function serve(routes) {
  const log = [];
  const server = http.createServer((req, res) => {
    log.push({ url: req.url, headers: req.headers });
    const r = routes.get(req.url.split("?")[0]);
    if (r === undefined) {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "not-found", message: `no route ${req.url}` }));
      return;
    }
    const out =
      typeof r === "function"
        ? r(req)
        : typeof r === "string" || Buffer.isBuffer(r)
          ? { body: r }
          : r;
    res.writeHead(out.status ?? 200, out.headers ?? {});
    res.end(out.body);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({ server, log, base: `http://127.0.0.1:${server.address().port}` });
    });
  });
}
