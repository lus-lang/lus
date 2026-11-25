#!/usr/bin/env node
// Reads the fields of an issue written with .github/ISSUE_TEMPLATE/bug.yml.
//
//   node tools/ci/issue.mjs BODY_FILE OUT_DIR
//
// It writes fields.json with every field of the form, and repro.lus with
// the program of the Reproduction field when that field holds one.

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

// GitHub renders each field of a form as a level-three heading followed by
// its answer, and "_No response_" for an empty one.
export function fields(body) {
  const out = {};
  let current = null;
  for (const line of (body ?? "").replace(/\r\n/g, "\n").split("\n")) {
    const h = /^###\s+(.+?)\s*$/.exec(line);
    if (h) {
      current = h[1].toLowerCase();
      out[current] = [];
    } else if (current) {
      out[current].push(line);
    }
  }
  for (const k of Object.keys(out)) {
    const text = out[k].join("\n").trim();
    out[k] = text === "_No response_" ? "" : text;
  }
  return out;
}

// The program of a Reproduction field: its first fenced block, or the whole
// field when it holds none.
export function program(text) {
  const m = /```[a-z]*\n([\s\S]*?)```/.exec(text ?? "");
  return (m ? m[1] : text ?? "").trim();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [file, dir] = process.argv.slice(2);
  const f = fields(fs.readFileSync(file, "utf8"));
  fs.mkdirSync(dir, {recursive: true});
  fs.writeFileSync(path.join(dir, "fields.json"), JSON.stringify(f, null, 2) + "\n");
  const code = program(f["reproduction"]);
  if (code) fs.writeFileSync(path.join(dir, "repro.lus"), code + "\n");
  console.log(`${Object.keys(f).length} fields, ${code ? "a program" : "no program"}`);
}
