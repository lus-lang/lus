// Runs Lus test files through lus.wasm, once with the JIT off and once
// with every function compiled on its first call, and compares the two.
//
// Usage: node scripts/conformance.mjs [--modes off,eager] [--wasm path] [--list-failures] [files or directories...]
//
// The default is every file of tests/conformance and of the language
// server tests. The directories of those files, the language server, and
// the stdlib specification are copied into the in-memory file system at their real paths, so fixtures load as they do
// under `lus test`. `lus test` itself runs
// each file in a child process, which WASI does not have, so this script
// is a small runner of its own. It finds the test functions of a file by
// their names, appends a footer that returns them, and calls each one from
// a driver chunk. It has the `skip`, `raises`, and `same` helpers of
// `lus test` and plain `assert`. Files that need the network, workers,
// processes, or the real file system fail under WebAssembly whatever the
// JIT does, so the result that matters is that both modes agree and that
// nothing crashes. The script exits with status 1 when the modes disagree
// on any test or when a test traps or panics the runtime.

import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLus, readHostDirectory } from "../src/node.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../..");

const LUS_OK = 0;

const PRELUDE = String.raw`
local catchfn = function(f, ...) return catch f(...) end
local function raises(f, pattern, ...)
    local ok, err = catchfn(f, ...)
    if ok then error("expected an error, but the call succeeded", 2) end
    if pattern ~= nil and not tostring(err):find(pattern) then
        error(` + "`expected an error matching '$(pattern)', got: $(tostring(err))`" + String.raw`, 2)
    end
    return err
end
local function same(a, b, seen)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do
        if not same(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
_G.raises = raises
_G.same = same
_G.skip = function(reason) error("\0lus-skip:" .. tostring(reason or ""), 0) end
_G.snapshot = function() error("\0lus-skip:snapshots are not available", 0) end
`;

// Runs every test of the registry and prints one record per test.
const DRIVER = String.raw`
local registry, cases = ...
local function record(label, ok, err)
    local status = "pass"
    if not ok then
        status = "fail"
        if type(err) == "string" and err:sub(1, 10) == "\0lus-skip:" then status = "skip" end
    end
    io.write("\30", status, "\t", label, "\t", (tostring(err):gsub("\n", " ")), "\n")
end
for i = 1, #registry, 2 do
    local name, f = registry[i], registry[i + 1]
    if type(f) == "function" then
        local list = cases[name:sub(1, -6) .. "_cases"]
        if type(list) == "table" then
            local n = 0
            for k, entry in ipairs(list) do
                n = k
                if type(entry) == "table" then
                    record(` + "`$(name)[$(k)]`" + String.raw`, catch f(table.unpack(entry)))
                else
                    record(` + "`$(name)[$(k)]`" + String.raw`, catch f(entry))
                end
            end
            for k, entry in pairs(list) do
                if not (math.type(k) == "integer" and k >= 1 and k <= n) then
                    if type(entry) == "table" then
                        record(` + "`$(name)[$(tostring(k))]`" + String.raw`, catch f(table.unpack(entry)))
                    else
                        record(` + "`$(name)[$(tostring(k))]`" + String.raw`, catch f(entry))
                    end
                end
            end
        else
            record(name, catch f())
        end
    end
end
`;

/** The names of the top-level tests and case tables of a file. */
export function testNames(source) {
  const tests = [];
  const cases = [];
  for (const line of source.split("\n")) {
    let m = /^(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*_test)\s*\(/.exec(line);
    if (!m) m = /^local\s+([A-Za-z_][A-Za-z0-9_]*_test)\s*=/.exec(line);
    if (m && !tests.includes(m[1])) tests.push(m[1]);
    const c = /^(?:local\s+|global\s+)?([A-Za-z_][A-Za-z0-9_]*_cases)\b/.exec(line);
    if (c && !cases.includes(c[1])) cases.push(c[1]);
  }
  return { tests, cases };
}

function footer({ tests, cases }) {
  const reg = tests.map((t) => `${JSON.stringify(t)}, ${t}`).join(", ");
  const cs = cases.map((c) => `${c} = ${c}`).join(", ");
  return `\nreturn { ${reg} }, { ${cs} }\n`;
}

/**
 * Runs one test file in a fresh state and returns its records:
 * `{ name: { status, message } }`, or `{ "(file)": ... }` when the file
 * itself fails to load or run.
 */
export function runFile(lus, file) {
  const source = readFileSync(file, "utf8");
  const names = testNames(source);
  lus.capture.reset();
  const results = {};
  const before = new Set(lus.fs.readdir("/"));
  let l;
  try {
    l = lus.create();
  } catch (error) {
    return { "(file)": { status: "fail", message: String(error) } };
  }
  const x = lus.exports;
  const fail = (what) => {
    const { message } = lus.takeError(l);
    results["(file)"] = { status: "fail", message: `${what}: ${message}` };
  };
  try {
    lus.guard(() => {
      const dir = path.dirname(file);
      if (lus.loadChunk(l, `${PRELUDE}\n_G.TEST_DIR = ${JSON.stringify(dir)}\n`, "=(prelude)") !== LUS_OK || x.lus_pcall(l, 0, 0) !== LUS_OK) {
        return fail("prelude");
      }
      if (lus.loadChunk(l, DRIVER, "=(driver)") !== LUS_OK) return fail("driver");
      if (lus.loadChunk(l, source + footer(names), `@${path.basename(file)}`) !== LUS_OK) return fail("load");
      if (x.lus_pcall(l, 0, 2) !== LUS_OK) return fail("setup");
      if (x.lus_pcall(l, 2, 0) !== LUS_OK) return fail("driver");
    });
  } catch (error) {
    results["(file)"] = { status: "fail", message: `trap: ${error}` };
  } finally {
    try {
      lus.destroy(l);
    } catch {
      // The instance is dead and is replaced on the next call.
    }
    // Each file starts from the same file system, as each file of
    // `lus test` starts in a fresh directory.
    for (const name of lus.fs.readdir("/")) if (!before.has(name)) lus.fs.remove(`/${name}`);
  }
  for (const line of lus.capture.text("stdout").split("\n")) {
    if (!line.startsWith("\x1e")) continue;
    const [status, name, message] = line.slice(1).split("\t");
    results[name] = { status, message };
  }
  return results;
}

function listFiles(args) {
  const files = [];
  for (const arg of args) {
    if (statSync(arg).isDirectory()) {
      for (const entry of readdirSync(arg).sort()) {
        if (entry.endsWith("_test.lus")) files.push(path.join(arg, entry));
      }
    } else files.push(arg);
  }
  return files;
}

// Temporary names differ between runs.
function normalize(message) {
  return message.replace(/[0-9a-f]{6,}|[0-9]+/g, "#");
}

function count(results) {
  const c = { pass: 0, fail: 0, skip: 0 };
  for (const r of Object.values(results)) c[r.status] = (c[r.status] ?? 0) + 1;
  return c;
}

async function main() {
  const args = process.argv.slice(2).filter((a) => a !== "--list-failures");
  let modes = ["off", "eager"];
  const i = args.indexOf("--modes");
  if (i >= 0) {
    modes = args[i + 1].split(",");
    args.splice(i, 2);
  }
  let wasmPath;
  const w = args.indexOf("--wasm");
  if (w >= 0) {
    wasmPath = args[w + 1];
    args.splice(w, 2);
  }
  const files = listFiles(args.length ? args : [path.join(root, "tests/conformance"), path.join(root, "packages/language-server/tests")]);
  const mounts = {};
  const dirs = new Set(files.map((f) => path.dirname(path.resolve(f))));
  for (const d of ["packages/language-server", "spec/stdlib"]) dirs.add(path.join(root, d));
  for (const dir of dirs) mounts[dir] = await readHostDirectory(dir, [""]);
  const byMode = {};
  for (const mode of modes) {
    const errors = [];
    const lus = await loadLus(wasmPath, { env: { LUS_JIT: mode }, jit: { onError: (e) => errors.push(String(e)) } });
    for (const [dir, files] of Object.entries(mounts)) lus.fs.mount(files, dir);
    const all = {};
    const totals = { pass: 0, fail: 0, skip: 0 };
    for (const file of files) {
      const r = runFile(lus, file);
      all[path.basename(file)] = r;
      const c = count(r);
      for (const k of Object.keys(totals)) totals[k] += c[k] ?? 0;
    }
    const jit = lus.jit?.runtimeStats();
    console.log(
      `${mode}: ${files.length} files, ${totals.pass} passed, ${totals.fail} failed, ${totals.skip} skipped` +
        (jit ? `, ${jit.compiled} functions compiled, ${jit.failed} declined by the host` : ""),
    );
    for (const e of errors.slice(0, 5)) console.log(`  host error: ${e}`);
    byMode[mode] = all;
  }
  // Compare every mode with the first.
  let differ = 0;
  const [first, ...rest] = modes;
  for (const mode of rest) {
    for (const [file, results] of Object.entries(byMode[first])) {
      const other = byMode[mode][file];
      const names = new Set([...Object.keys(results), ...Object.keys(other)]);
      for (const name of names) {
        const a = results[name];
        const b = other[name];
        if (a?.status !== b?.status || (a?.status === "fail" && normalize(a.message) !== normalize(b.message))) {
          differ++;
          console.log(`DIFF ${file} ${name}\n  ${first}: ${a?.status} ${a?.message ?? ""}\n  ${mode}: ${b?.status} ${b?.message ?? ""}`);
        }
      }
    }
  }
  if (process.argv.includes("--list-failures")) {
    for (const [file, results] of Object.entries(byMode[first])) {
      for (const [name, r] of Object.entries(results)) if (r.status === "fail") console.log(`FAIL ${file} ${name}: ${r.message}`);
    }
  }
  console.log(differ === 0 ? "The modes agree on every test." : `${differ} tests differ between the modes.`);
  // A trap or a runtime panic is a bug in every mode, so it fails the run
  // even when the modes agree.
  let crashes = 0;
  for (const mode of modes) {
    for (const [file, results] of Object.entries(byMode[mode])) {
      for (const [name, r] of Object.entries(results)) {
        if (r.status === "fail" && /^trap: |runtime crashed/.test(r.message ?? "")) {
          crashes++;
          console.log(`CRASH ${mode} ${file} ${name}: ${r.message}`);
        }
      }
    }
  }
  if (crashes > 0) console.log(`${crashes} tests crashed the runtime.`);
  process.exitCode = differ === 0 && crashes === 0 ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
