#!/usr/bin/env node
// Generates lus-language/analysis/stdlib_data.lus from lus-spec/stdlib/ entries.
// Run: node lus-spec/build-lsp.js

const fs = require("fs");
const path = require("path");

const SPEC_DIR = path.join(__dirname, "stdlib");
const OUT_FILE = path.join(__dirname, "..", "lus-language", "analysis", "stdlib_data.lus");

// Simple YAML frontmatter parser (no dependency on js-yaml)
function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return null;
  const fm = {};
  let currentKey = null;
  let currentArray = null;
  let currentObj = null;

  for (const line of match[1].split("\n")) {
    // Array item with object (e.g., "  - name: foo")
    const arrayObjMatch = line.match(/^  - (\w+): (.+)$/);
    if (arrayObjMatch && currentKey) {
      currentObj = { [arrayObjMatch[1]]: parseVal(arrayObjMatch[2]) };
      if (!currentArray) currentArray = [];
      currentArray.push(currentObj);
      fm[currentKey] = currentArray;
      continue;
    }

    // Object continuation (e.g., "    type: bar")
    const objContMatch = line.match(/^    (\w+): (.+)$/);
    if (objContMatch && currentObj) {
      currentObj[objContMatch[1]] = parseVal(objContMatch[2]);
      continue;
    }

    // Top-level key
    const topMatch = line.match(/^(\w+): (.+)$/);
    if (topMatch) {
      currentKey = topMatch[1];
      currentArray = null;
      currentObj = null;
      fm[currentKey] = parseVal(topMatch[2]);
      continue;
    }

    // Array start with no value (e.g., "params:")
    const arrayStartMatch = line.match(/^(\w+):$/);
    if (arrayStartMatch) {
      currentKey = arrayStartMatch[1];
      currentArray = [];
      currentObj = null;
      fm[currentKey] = currentArray;
      continue;
    }
  }
  return fm;
}

function parseVal(s) {
  s = s.trim();
  if (s === "true") return true;
  if (s === "false") return false;
  if (s.startsWith('"') && s.endsWith('"')) return s.slice(1, -1);
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  return s;
}

// Recursively find all .md files
function findMd(dir) {
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findMd(full));
    } else if (entry.name.endsWith(".md") && entry.name !== "_module.md") {
      results.push(full);
    }
  }
  return results;
}

// Map from frontmatter kind to LSP CompletionItemKind integer
const KIND_MAP = {
  function: 3,   // Function
  constant: 21,  // Constant
  variable: 6,   // Variable
  module: 9,     // Module
};

// Collect all stdlib entries
const files = findMd(SPEC_DIR);
const entries = [];

for (const file of files) {
  const content = fs.readFileSync(file, "utf-8");
  const fm = parseFrontmatter(content);
  if (!fm || !fm.name) continue;
  if (fm.stability === "removed") continue; // skip removed entries
  // Extract markdown body (text after closing ---)
  const bodyMatch = content.match(/^---\n[\s\S]*?\n---\n?([\s\S]*)$/);
  fm._body = bodyMatch ? bodyMatch[1].trim() : "";
  entries.push(fm);
}

// Organize data
const globals = [];        // Global function/variable names
const tables = [];         // Stdlib table names (string, math, etc.)
const members = {};        // { moduleName: [{n, k}, ...] }
const signatures = {};     // { "module.name": ["param1", "param2", ...] }
const fields = {};         // { moduleName: {fieldName: kindString} }
const descriptions = {};   // { "module.name": "markdown body" }
const returns = {};        // { "module.name": "return_type_string" }
const generics = {};       // { "module.name": "T" }

// Track which module names we've seen
const moduleNames = new Set();

for (const e of entries) {
  const mod = e.module || "base";
  const isGlobal = mod === "base";
  const bareName = e.name.includes(".") ? e.name.split(".").pop() : e.name;

  if (isGlobal) {
    globals.push(e.name);
  } else {
    // Determine the top-level module for grouping
    // e.g., "fs.path.join" -> module "fs", but stored under "fs.path"
    const qualParts = e.name.split(".");
    const parentModule = qualParts.slice(0, -1).join(".");

    if (!moduleNames.has(parentModule)) {
      moduleNames.add(parentModule);
    }

    if (!members[parentModule]) members[parentModule] = [];
    members[parentModule].push({ n: bareName, k: KIND_MAP[e.kind] || 3 });

    if (!fields[parentModule]) fields[parentModule] = {};
    fields[parentModule][bareName] = e.kind;
  }

  // Build signatures for functions (with types)
  if (e.kind === "function" && e.params) {
    const paramList = e.params.map(p => ({
      n: p.name,
      t: p.type || "any",
      opt: p.optional || false,
    }));
    if (e.vararg) paramList.push({ n: "...", t: "any", opt: false });
    signatures[e.name] = paramList;
  }

  // Store markdown body as description
  if (e._body) {
    descriptions[e.name] = e._body;
  }

  // Collect return types and generics
  if (e.returns) {
    // returns can be a string ("table") or an array of {type, name} objects
    if (Array.isArray(e.returns)) {
      returns[e.name] = e.returns.map(r => r.type || "any").join(", ");
    } else {
      returns[e.name] = e.returns;
    }
  }
  if (e.generic) {
    generics[e.name] = e.generic;
  }
}

// Add sub-module entries to parent modules (e.g., "path" in "fs", "tcp"/"udp" in "network")
for (const mod of Object.keys(members)) {
  if (mod.includes(".")) {
    const parts = mod.split(".");
    const parent = parts.slice(0, -1).join(".");
    const child = parts[parts.length - 1];
    if (members[parent]) {
      // Check if already present
      const exists = members[parent].some(m => m.n === child);
      if (!exists) {
        members[parent].push({ n: child, k: KIND_MAP.module });
      }
    }
    if (fields[parent]) {
      if (!fields[parent][child]) {
        fields[parent][child] = "module";
      }
    }
  }
}

// Add the top-level module names to tables array
const TOP_MODULES = [
  "string", "table", "math", "io", "os", "debug",
  "coroutine", "utf8", "fs", "network", "worker", "vector", "package",
];

for (const mod of TOP_MODULES) {
  if (moduleNames.has(mod) || members[mod]) {
    tables.push(mod);
  }
}

// Also add _ENV (not in spec files but needed by linting)
if (!globals.includes("_ENV")) globals.push("_ENV");

// Deduplicate globals
const seen = new Set();
const uniqueGlobals = [];
for (const g of globals) {
  if (!seen.has(g)) { seen.add(g); uniqueGlobals.push(g); }
}
globals.length = 0;
globals.push(...uniqueGlobals);

// Generate Lus source
function luaStr(s) {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function luaLongStr(s) {
  let level = 0;
  while (s.includes("]" + "=".repeat(level) + "]")) level++;
  const eq = "=".repeat(level);
  return `[${eq}[\n${s}]${eq}]`;
}

function luaArr(arr) {
  return "{ " + arr.map(s => luaStr(s)).join(", ") + " }";
}

let out = `-- AUTO-GENERATED by lus-spec/build-lsp.js — DO NOT EDIT
-- Source: lus-spec/stdlib/**/*.md

local M = {}

-- Global names (functions + variables + tables) for linting/rename/semantic_tokens
M.globals = ${luaArr(globals)}

-- Stdlib table names
M.tables = ${luaArr(tables)}

-- Members per library (for completion/hover)
M.members = {
`;

// Sort members by module name
const sortedModules = Object.keys(members).sort();
for (const mod of sortedModules) {
  const items = members[mod];
  out += `  [${luaStr(mod)}] = {\n`;
  for (const item of items) {
    out += `    {n = ${luaStr(item.n)}, k = ${item.k}},\n`;
  }
  out += `  },\n`;
}
out += `}\n\n`;

// Fields (for hover kind detection)
out += `-- Field kinds per library (for hover)\nM.fields = {\n`;
for (const mod of sortedModules) {
  const f = fields[mod];
  if (!f) continue;
  out += `  [${luaStr(mod)}] = {\n`;
  for (const [name, kind] of Object.entries(f).sort()) {
    out += `    [${luaStr(name)}] = ${luaStr(kind)},\n`;
  }
  out += `  },\n`;
}
out += `}\n\n`;

// Signatures (with types)
out += `-- Parameter lists with types (for signature help / hover / inlay hints)
-- Each entry: { {n="name", t="type", opt=bool}, ... }
M.signatures = {\n`;
const sortedSigs = Object.keys(signatures).sort();
for (const name of sortedSigs) {
  const params = signatures[name];
  const items = params.map(p => {
    let s = `{n = ${luaStr(p.n)}, t = ${luaStr(p.t)}`;
    if (p.opt) s += `, opt = true`;
    s += `}`;
    return s;
  });
  out += `  [${luaStr(name)}] = {${items.join(", ")}},\n`;
}
out += `}\n\n`;

// Return types (for type inference / hover / signature help)
out += `-- Return types (for type inference / hover / signature help)\nM.returns = {\n`;
const sortedReturns = Object.keys(returns).sort();
for (const name of sortedReturns) {
  out += `  [${luaStr(name)}] = ${luaStr(returns[name])},\n`;
}
out += `}\n\n`;

// Generics (for parametric type resolution)
out += `-- Generic type variables (for parametric type resolution)\nM.generics = {\n`;
const sortedGenerics = Object.keys(generics).sort();
for (const name of sortedGenerics) {
  out += `  [${luaStr(name)}] = ${luaStr(generics[name])},\n`;
}
out += `}\n\n`;

// Descriptions (from markdown body, for hover)
out += `-- Documentation from markdown body (for hover)\nM.descriptions = {\n`;
const sortedDescs = Object.keys(descriptions).sort();
for (const name of sortedDescs) {
  out += `  [${luaStr(name)}] = ${luaLongStr(descriptions[name])},\n`;
}
out += `}\n\nreturn M\n`;

// Write output
fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
fs.writeFileSync(OUT_FILE, out);

console.log(`Generated ${OUT_FILE}`);
console.log(`  ${globals.length} globals, ${tables.length} tables, ${sortedModules.length} modules, ${sortedSigs.length} signatures`);
