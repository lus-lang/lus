#!/usr/bin/env node
// Generator script for lus-spec markdown files.
// Run: node lus-spec/generate.js

const fs = require("fs");
const path = require("path");

const SPEC = path.join(__dirname);

function yaml(obj) {
  let lines = ["---"];
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    if (Array.isArray(v)) {
      if (v.length === 0) continue;
      if (typeof v[0] === "object") {
        lines.push(`${k}:`);
        for (const item of v) {
          let first = true;
          for (const [ik, iv] of Object.entries(item)) {
            if (iv === undefined) continue;
            if (first) {
              lines.push(`  - ${ik}: ${yamlVal(iv)}`);
              first = false;
            } else {
              lines.push(`    ${ik}: ${yamlVal(iv)}`);
            }
          }
        }
      } else {
        lines.push(`${k}:`);
        for (const item of v) lines.push(`  - ${yamlVal(item)}`);
      }
    } else if (typeof v === "string" && v.includes("\n")) {
      lines.push(`${k}: |`);
      for (const l of v.split("\n")) lines.push(`  ${l}`);
    } else {
      lines.push(`${k}: ${yamlVal(v)}`);
    }
  }
  lines.push("---");
  return lines.join("\n");
}

function yamlVal(v) {
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (typeof v === "string") {
    if (/[:{}\[\],&*#?|<>=!%@`'"]/.test(v) || v === "" || v === "true" || v === "false" || v === "null")
      return `"${v.replace(/"/g, '\\"')}"`;
    return v;
  }
  return String(v);
}

function writeSpec(relPath, frontmatter, body = "") {
  const full = path.join(SPEC, relPath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  const content = yaml(frontmatter) + "\n\n" + body.trim() + "\n";
  fs.writeFileSync(full, content);
}

function stdlibFunc(mod, name, params, opts = {}) {
  const fqn = mod === "base" ? name : `${mod}.${name}`;
  const hasVararg = params.some(p => p === "...");
  const paramObjs = params.filter(p => p !== "...").map((p, i, arr) => {
    const obj = { name: p, type: "any" };
    if (opts.optionalFrom !== undefined && i >= opts.optionalFrom) obj.optional = true;
    return obj;
  });
  return {
    name: fqn,
    module: mod.split(".")[0],
    kind: "function",
    since: "0.1.0",
    stability: opts.stability || "stable",
    origin: opts.origin || "lua",
    params: paramObjs.length ? paramObjs : undefined,
    vararg: hasVararg || undefined,
  };
}

// ─── STDLIB DATA ───

const GLOBAL_FUNCS = {
  assert:           { params: ["v", "message"], optFrom: 1 },
  collectgarbage:   { params: ["opt", "arg"], optFrom: 0 },
  dofile:           { params: ["filename"], optFrom: 0 },
  error:            { params: ["message", "level"], optFrom: 1 },
  getmetatable:     { params: ["object"] },
  ipairs:           { params: ["t"] },
  load:             { params: ["chunk", "chunkname", "mode", "env"], optFrom: 1 },
  loadfile:         { params: ["filename", "mode", "env"], optFrom: 0 },
  next:             { params: ["t", "k"], optFrom: 1 },
  pairs:            { params: ["t"] },
  print:            { params: ["..."] },
  rawequal:         { params: ["v1", "v2"] },
  rawget:           { params: ["t", "k"] },
  rawlen:           { params: ["v"] },
  rawset:           { params: ["t", "k", "v"] },
  require:          { params: ["modname"] },
  select:           { params: ["index", "..."] },
  setmetatable:     { params: ["t", "metatable"] },
  tonumber:         { params: ["e", "base"], optFrom: 1 },
  tostring:         { params: ["v"] },
  type:             { params: ["v"] },
  warn:             { params: ["msg1", "..."] },
  pledge:           { params: ["name..."], origin: "lus" },
  fromjson:         { params: ["s"], origin: "lus" },
  tojson:           { params: ["value", "filter"], origin: "lus", optFrom: 1 },
  pcall:            { params: ["f", "..."], stability: "removed" },
  xpcall:           { params: ["f", "msgh", "..."], stability: "removed" },
};

const GLOBAL_VARS = {
  _G:       { kind: "variable", type: "table", body: "A global variable (not a function) that holds the global environment." },
  _VERSION: { kind: "variable", type: "string", body: "A global variable containing the running Lus version string." },
};

const STRING = {
  byte:      { params: ["s", "i", "j"], optFrom: 1 },
  char:      { params: ["..."] },
  dump:      { params: ["function", "strip"], optFrom: 1 },
  find:      { params: ["s", "pattern", "init", "plain"], optFrom: 2 },
  format:    { params: ["formatstring", "..."] },
  gmatch:    { params: ["s", "pattern", "init"], optFrom: 2 },
  gsub:      { params: ["s", "pattern", "repl", "n"], optFrom: 3 },
  len:       { params: ["s"] },
  lower:     { params: ["s"] },
  match:     { params: ["s", "pattern", "init"], optFrom: 2 },
  rep:       { params: ["s", "n", "sep"], optFrom: 2 },
  reverse:   { params: ["s"] },
  sub:       { params: ["s", "i", "j"], optFrom: 2 },
  upper:     { params: ["s"] },
  pack:      { params: ["fmt", "..."] },
  packsize:  { params: ["fmt"] },
  unpack:    { params: ["fmt", "s", "pos"], optFrom: 2 },
  transcode: { params: ["s", "from", "to"], origin: "lus" },
};

const TABLE = {
  clone:  { params: ["t", "deep"], optFrom: 1, origin: "lus" },
  concat: { params: ["list", "sep", "i", "j"], optFrom: 1 },
  create: { params: ["narray", "nhash"], optFrom: 1 },
  insert: { params: ["list", "pos", "value"], optFrom: 1 },
  move:   { params: ["a1", "f", "e", "t", "a2"], optFrom: 4 },
  pack:   { params: ["..."] },
  remove: { params: ["list", "pos"], optFrom: 1 },
  sort:   { params: ["list", "comp"], optFrom: 1 },
  unpack: { params: ["list", "i", "j"], optFrom: 1 },
};

const MATH_FUNCS = {
  abs:        { params: ["x"] },
  acos:       { params: ["x"] },
  asin:       { params: ["x"] },
  atan:       { params: ["y", "x"], optFrom: 1 },
  ceil:       { params: ["x"] },
  cos:        { params: ["x"] },
  deg:        { params: ["x"] },
  exp:        { params: ["x"] },
  floor:      { params: ["x"] },
  fmod:       { params: ["x", "y"] },
  frexp:      { params: ["x"] },
  ldexp:      { params: ["m", "e"] },
  log:        { params: ["x", "base"], optFrom: 1 },
  max:        { params: ["x", "..."] },
  min:        { params: ["x", "..."] },
  modf:       { params: ["x"] },
  rad:        { params: ["x"] },
  random:     { params: ["m", "n"], optFrom: 0 },
  randomseed: { params: ["x", "y"], optFrom: 0 },
  sin:        { params: ["x"] },
  sqrt:       { params: ["x"] },
  tan:        { params: ["x"] },
  tointeger:  { params: ["x"] },
  type:       { params: ["x"] },
  ult:        { params: ["m", "n"] },
};

const MATH_CONSTS = {
  pi:         { type: "number", body: "The value of pi." },
  huge:       { type: "number", body: "The float value `HUGE_VAL`, greater than any other numeric value." },
  maxinteger: { type: "integer", body: "The maximum value for an integer." },
  mininteger: { type: "integer", body: "The minimum value for an integer." },
};

const IO_FUNCS = {
  close:   { params: ["file"], optFrom: 0 },
  flush:   { params: [] },
  input:   { params: ["file"], optFrom: 0 },
  lines:   { params: ["filename", "..."], optFrom: 0 },
  open:    { params: ["filename", "mode"], optFrom: 1 },
  output:  { params: ["file"], optFrom: 0 },
  popen:   { params: ["prog", "mode"], optFrom: 1 },
  read:    { params: ["..."] },
  tmpfile: { params: [] },
  type:    { params: ["obj"] },
  write:   { params: ["..."] },
};

const IO_VARS = {
  stdin:  { type: "file", body: "Standard input file handle." },
  stdout: { type: "file", body: "Standard output file handle." },
  stderr: { type: "file", body: "Standard error file handle." },
};

const OS_FUNCS = {
  clock:     { params: [] },
  date:      { params: ["format", "time"], optFrom: 0 },
  difftime:  { params: ["t2", "t1"] },
  execute:   { params: ["command"], optFrom: 0 },
  exit:      { params: ["code", "close"], optFrom: 0 },
  getenv:    { params: ["varname"] },
  platform:  { params: [], origin: "lus" },
  remove:    { params: ["filename"], stability: "removed" },
  rename:    { params: ["oldname", "newname"], stability: "removed" },
  setlocale: { params: ["locale", "category"], optFrom: 0 },
  time:      { params: ["t"], optFrom: 0 },
  tmpname:   { params: [] },
};

const DEBUG_FUNCS = {
  debug:        { params: [] },
  format:       { params: ["source", "chunkname", "indent_width"], optFrom: 1, origin: "lus" },
  gethook:      { params: ["thread"], optFrom: 0 },
  getinfo:      { params: ["f", "what"], optFrom: 1 },
  getlocal:     { params: ["f", "local_"], optFrom: 1 },
  getmetatable: { params: ["value"] },
  getregistry:  { params: [] },
  getupvalue:   { params: ["f", "up"] },
  getuservalue: { params: ["u", "n"], optFrom: 1 },
  parse:        { params: ["code", "chunkname", "options"], optFrom: 1, origin: "lus" },
  sethook:      { params: ["hook", "mask", "count"], optFrom: 2 },
  setlocal:     { params: ["level", "local_", "value"] },
  setmetatable: { params: ["value", "t"] },
  setupvalue:   { params: ["f", "up", "value"] },
  setuservalue: { params: ["u", "value", "n"], optFrom: 2 },
  traceback:    { params: ["message", "level"], optFrom: 0 },
  upvalueid:    { params: ["f", "n"] },
  upvaluejoin:  { params: ["f1", "n1", "f2", "n2"] },
};

const COROUTINE = {
  close:       { params: ["co"] },
  create:      { params: ["f"] },
  isyieldable: { params: [] },
  resume:      { params: ["co", "..."] },
  running:     { params: [] },
  status:      { params: ["co"] },
  wrap:        { params: ["f"] },
  yield:       { params: ["..."] },
};

const UTF8_FUNCS = {
  char:      { params: ["..."] },
  codepoint: { params: ["s", "i", "j"], optFrom: 1 },
  codes:     { params: ["s"] },
  len:       { params: ["s", "i", "j"], optFrom: 1 },
  offset:    { params: ["s", "n", "i"], optFrom: 2 },
};

const UTF8_CONSTS = {
  charpattern: { type: "string", body: "The pattern which matches exactly one UTF-8 byte sequence." },
};

const FS_FUNCS = {
  copy:            { params: ["source", "dest"], origin: "lus" },
  createdirectory: { params: ["path"], origin: "lus" },
  createlink:      { params: ["target", "link"], origin: "lus" },
  follow:          { params: ["path"], origin: "lus" },
  list:            { params: ["path"], origin: "lus" },
  move:            { params: ["source", "dest"], origin: "lus" },
  remove:          { params: ["path"], origin: "lus" },
  type:            { params: ["path"], origin: "lus" },
};

const FS_PATH_FUNCS = {
  join:   { params: ["..."], origin: "lus" },
  name:   { params: ["path"], origin: "lus" },
  parent: { params: ["path"], origin: "lus" },
  split:  { params: ["path"], origin: "lus" },
};

const FS_PATH_CONSTS = {
  separator: { type: "string", origin: "lus", body: "The platform path separator (`/` on POSIX, `\\` on Windows)." },
  delimiter: { type: "string", origin: "lus", body: "The platform path list delimiter (`:` on POSIX, `;` on Windows)." },
};

const NETWORK_FUNCS = {
  fetch: { params: ["url", "options"], optFrom: 1, origin: "lus" },
};

const NETWORK_TCP = {
  connect: { params: ["host", "port"], origin: "lus" },
  bind:    { params: ["host", "port"], origin: "lus" },
};

const NETWORK_UDP = {
  open: { params: ["host", "port"], origin: "lus" },
};

const WORKER = {
  create:  { params: ["path", "..."], origin: "lus" },
  message: { params: ["value"], origin: "lus" },
  peek:    { params: [], origin: "lus" },
  receive: { params: ["w1", "..."], origin: "lus" },
  send:    { params: ["w", "value"], origin: "lus" },
  status:  { params: ["w"], origin: "lus" },
};

const VECTOR = {
  clone:      { params: ["v"], origin: "lus" },
  create:     { params: ["capacity", "fast"], optFrom: 1, origin: "lus" },
  pack:       { params: ["v", "offset", "fmt", "..."], origin: "lus" },
  resize:     { params: ["v", "newsize"], origin: "lus" },
  size:       { params: ["v"], origin: "lus" },
  unpack:     { params: ["v", "offset", "fmt"], origin: "lus" },
  unpackmany: { params: ["v", "offset", "fmt", "count"], optFrom: 3, origin: "lus" },
};

const PACKAGE_FUNCS = {
  loadlib:    { params: ["libname", "funcname"] },
  searchpath: { params: ["name", "path", "sep", "rep"], optFrom: 2 },
};

const PACKAGE_VARS = {
  config:    { type: "string", body: "A string describing some compile-time configurations for packages." },
  cpath:     { type: "string", body: "The path used by `require` to search for a C loader." },
  loaded:    { type: "table", body: "A table used by `require` to control which modules are already loaded." },
  path:      { type: "string", body: "The path used by `require` to search for a Lus loader." },
  preload:   { type: "table", body: "A table to store loaders for specific modules." },
  searchers: { type: "table", body: "A table holding the sequence of searcher functions used by `require`." },
};

// ─── PROSE for Lus-specific entries ───

const PROSE = {
  "pledge": "Grants or checks a permission. Returns `true` if the permission was granted, `false` if it was denied or the state is sealed.\n\nThe `name` arguments specify the permissions to grant or check.\n\nSpecial permissions: `\"all\"` grants all permissions (CLI only), `\"seal\"` prevents future permission changes. The `~` prefix rejects a permission permanently.\n\n```lus\npledge(\"fs\")           -- grant filesystem access\npledge(\"fs:read=/tmp\") -- grant read access to /tmp only\npledge(\"~network\")     -- reject network permission\npledge(\"seal\")         -- lock permissions\n```",
  "worker.create": "Spawns a new worker running the script at `path`. Optional varargs are serialized and can be received by the worker via `worker.peek()`. Returns a worker handle. Requires `load` and `fs:read` pledges.\n\n```lus\nlocal w = worker.create(\"worker.lus\", \"hello\", 42)\n-- worker can receive \"hello\" and 42 via worker.peek()\n```",
  "worker.status": "Returns the status of worker `w`: `\"running\"` if the worker is still executing, or `\"dead\"` if it has finished or errored.",
  "worker.receive": "Blocking select-style receive from one or more workers. Blocks until at least one worker has a message. Returns one value per worker: the message if available, or `nil` if that worker has no message. Propagates worker errors.\n\n```lus\nlocal msg = worker.receive(w)\n-- or multi-worker select:\nlocal m1, m2 = worker.receive(w1, w2)\n```",
  "worker.send": "Sends `value` to worker `w`'s inbox. The worker can receive it via `worker.peek()`. Values are deep-copied.",
  "worker.message": "*(Worker-side only)* Sends `value` to the worker's outbox for the parent to receive via `worker.receive()`.",
  "worker.peek": "*(Worker-side only)* Blocking receive from the worker's inbox. Blocks until a message from the parent (via `worker.send()`) is available.",
  "debug.parse": "Parses a Lus source string and returns its AST (Abstract Syntax Tree) as a nested table structure. Returns `nil` if parsing fails.\n\nThe optional `chunkname` argument specifies the name used in error messages (defaults to `\"=(parse)\"`).\n\n```lus\nlocal ast = debug.parse(\"local x = 1 + 2\")\n-- Returns: {type = \"chunk\", line = 1, children = {...}}\n```\n\nEach AST node is a table with at minimum `type` (node type string) and `line` (source line number).",
  "debug.format": "Formats Lus source code. Returns the formatted source string.\n\nThe optional `chunkname` specifies the name used in error messages. The optional `indent_width` sets the indentation width (defaults to 2).",
  "vector.create": "Creates a new vector with the given `capacity` in bytes. If `fast` is true, the buffer is not zero-initialized (faster but contents are undefined).\n\n```lus\nlocal v = vector.create(1024)        -- zero-initialized\nlocal v = vector.create(1024, true)  -- fast, uninitialized\n```",
  "vector.pack": "Packs values into the vector `v` starting at `offset`. Uses the same format string as `string.pack`.\n\n```lus\nlocal v = vector.create(16)\nvector.pack(v, 0, \"I4I4I4\", 1, 2, 3)\n```",
  "vector.unpack": "Unpacks values from the vector `v` starting at `offset`. Uses the same format string as `string.unpack`. Returns unpacked values followed by the next offset.\n\n```lus\nlocal a, b, c, nextpos = vector.unpack(v, 0, \"I4I4I4\")\n```",
  "vector.clone": "Creates a copy of the vector `v`.",
  "vector.size": "Returns the size of the vector in bytes. Equivalent to `#v`.",
  "vector.resize": "Resizes the vector to `newsize` bytes. New bytes are zero-initialized. Existing data within the new size is preserved.",
  "vector.unpackmany": "Returns an iterator that repeatedly unpacks values from `v` using the format `fmt`. Optional `count` limits the number of iterations.\n\n```lus\nfor a, b in vector.unpackmany(v, 0, \"I4I4\") do\n  print(a, b)\nend\n```",
  "table.clone": "Creates a copy of the table `t`. If `deep` is true, nested tables are recursively cloned. Deep copies preserve circular references.\n\n```lus\nlocal x = table.clone(t)        -- shallow copy\nlocal y = table.clone(t, true)  -- deep copy\n```",
  "string.transcode": "Transcodes string `s` from encoding `from` to encoding `to`. Supported encodings depend on the platform.",
  "os.platform": "Returns a string identifying the current platform (e.g., `\"macos\"`, `\"linux\"`, `\"windows\"`).",
  "fromjson": "Parses a JSON string `s` and returns the corresponding Lus value. Tables become Lus tables, JSON null becomes `nil`.",
  "tojson": "Converts a Lus value to a JSON string. The optional `filter` argument controls serialization. Objects with a `__json` metamethod use it for custom serialization.",
};

// ─── GENERATE STDLIB ───

function genStdlibFuncs(mod, funcs, dirPrefix) {
  for (const [name, info] of Object.entries(funcs)) {
    const fm = stdlibFunc(mod, name, info.params || [], {
      origin: info.origin,
      stability: info.stability,
      optionalFrom: info.optFrom,
    });
    const fqn = mod === "base" ? name : `${mod}.${name}`;
    const prose = PROSE[fqn] || "";
    writeSpec(`${dirPrefix}/${name}.md`, fm, prose);
  }
}

function genStdlibConsts(mod, consts, dirPrefix) {
  for (const [name, info] of Object.entries(consts)) {
    const fqn = `${mod}.${name}`;
    writeSpec(`${dirPrefix}/${name}.md`, {
      name: fqn,
      module: mod.split(".")[0],
      kind: "constant",
      since: "0.1.0",
      stability: "stable",
      origin: info.origin || "lua",
      type: info.type,
    }, info.body || "");
  }
}

function genStdlibVars(mod, vars, dirPrefix) {
  for (const [name, info] of Object.entries(vars)) {
    const fqn = mod === "base" ? name : `${mod}.${name}`;
    writeSpec(`${dirPrefix}/${name}.md`, {
      name: fqn,
      module: mod === "base" ? "base" : mod.split(".")[0],
      kind: "variable",
      since: "0.1.0",
      stability: "stable",
      origin: info.origin || "lua",
      type: info.type,
    }, info.body || "");
  }
}

function genModuleEntry(mod, parent, dirPrefix, origin) {
  writeSpec(`${dirPrefix}/_module.md`, {
    name: mod,
    module: parent,
    kind: "module",
    since: "0.1.0",
    stability: "stable",
    origin: origin,
  }, `The \`${mod}\` sub-module.`);
}

// Base globals
genStdlibFuncs("base", GLOBAL_FUNCS, "stdlib/base");
genStdlibVars("base", GLOBAL_VARS, "stdlib/base");

// String
genStdlibFuncs("string", STRING, "stdlib/string");

// Table
genStdlibFuncs("table", TABLE, "stdlib/table");

// Math
genStdlibFuncs("math", MATH_FUNCS, "stdlib/math");
genStdlibConsts("math", MATH_CONSTS, "stdlib/math");

// IO
genStdlibFuncs("io", IO_FUNCS, "stdlib/io");
genStdlibVars("io", IO_VARS, "stdlib/io");

// OS
genStdlibFuncs("os", OS_FUNCS, "stdlib/os");

// Debug
genStdlibFuncs("debug", DEBUG_FUNCS, "stdlib/debug");

// Coroutine
genStdlibFuncs("coroutine", COROUTINE, "stdlib/coroutine");

// UTF-8
genStdlibFuncs("utf8", UTF8_FUNCS, "stdlib/utf8");
genStdlibConsts("utf8", UTF8_CONSTS, "stdlib/utf8");

// FS
genStdlibFuncs("fs", FS_FUNCS, "stdlib/fs");
genModuleEntry("fs.path", "fs", "stdlib/fs/path", "lus");
genStdlibFuncs("fs.path", FS_PATH_FUNCS, "stdlib/fs/path");
genStdlibConsts("fs.path", FS_PATH_CONSTS, "stdlib/fs/path");

// Network
genStdlibFuncs("network", NETWORK_FUNCS, "stdlib/network");
genModuleEntry("network.tcp", "network", "stdlib/network/tcp", "lus");
genStdlibFuncs("network.tcp", NETWORK_TCP, "stdlib/network/tcp");
genModuleEntry("network.udp", "network", "stdlib/network/udp", "lus");
genStdlibFuncs("network.udp", NETWORK_UDP, "stdlib/network/udp");

// Worker
genStdlibFuncs("worker", WORKER, "stdlib/worker");

// Vector
genStdlibFuncs("vector", VECTOR, "stdlib/vector");

// Package
genStdlibFuncs("package", PACKAGE_FUNCS, "stdlib/package");
genStdlibVars("package", PACKAGE_VARS, "stdlib/package");

// JSON (tojson/fromjson are globals but logically from json library)
// Already generated under base/ as global functions

// ─── C API DATA ───

function capiFunc(name, header, sig, params, opts = {}) {
  return {
    name,
    header,
    kind: "function",
    since: "0.1.0",
    stability: opts.stability || "stable",
    origin: opts.origin || "lua",
    signature: `"${sig}"`,
    params: params.map(p => ({ name: p.name, type: p.type })),
    returns: opts.returns,
  };
}

function writeCapi(dir, name, fm, body = "") {
  writeSpec(`capi/${dir}/${name}.md`, fm, body);
}

// Helper to generate C API function entries
function coreFunc(name, sig, params, opts = {}) {
  const fm = {
    name,
    header: "lua.h",
    kind: "function",
    since: "0.1.0",
    stability: opts.stability || "stable",
    origin: opts.origin || "lua",
    signature: sig,
    params: params.length ? params : undefined,
    returns: opts.returns,
  };
  writeCapi("core", name, fm, opts.body || "");
}

function auxFunc(name, sig, params, opts = {}) {
  const fm = {
    name,
    header: "lauxlib.h",
    kind: "function",
    since: "0.1.0",
    stability: opts.stability || "stable",
    origin: opts.origin || "lua",
    signature: sig,
    params: params.length ? params : undefined,
    returns: opts.returns,
  };
  writeCapi("auxiliary", name, fm, opts.body || "");
}

// ─── lua.h TYPES ───

const CORE_TYPES = [
  { name: "lua_State", sig: "typedef struct lua_State lua_State;", body: "An opaque structure that points to a thread and indirectly to the whole state of a Lua interpreter." },
  { name: "lua_Number", sig: "typedef double lua_Number;", body: "The type of floats in Lua." },
  { name: "lua_Integer", sig: "typedef long long lua_Integer;", body: "The type of integers in Lua." },
  { name: "lua_Unsigned", sig: "typedef unsigned long long lua_Unsigned;", body: "The unsigned version of `lua_Integer`." },
  { name: "lua_KContext", sig: "typedef intptr_t lua_KContext;", body: "The type for continuation-function contexts." },
  { name: "lua_CFunction", sig: "typedef int (*lua_CFunction)(lua_State *L);", body: "Type for C functions that can be registered with Lua." },
  { name: "lua_KFunction", sig: "typedef int (*lua_KFunction)(lua_State *L, int status, lua_KContext ctx);", body: "Type for continuation functions." },
  { name: "lua_Reader", sig: "typedef const char *(*lua_Reader)(lua_State *L, void *ud, size_t *sz);", body: "The reader function used by `lua_load`." },
  { name: "lua_Writer", sig: "typedef int (*lua_Writer)(lua_State *L, const void *p, size_t sz, void *ud);", body: "The writer function used by `lua_dump`." },
  { name: "lua_Alloc", sig: "typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);", body: "The type of the memory-allocation function used by Lua states." },
  { name: "lua_WarnFunction", sig: "typedef void (*lua_WarnFunction)(void *ud, const char *msg, int tocont);", body: "The type of warning functions." },
  { name: "lua_Hook", sig: "typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);", body: "Type for debugging hook functions." },
  { name: "lua_Debug", sig: "struct lua_Debug { int event; const char *name; const char *namewhat; const char *what; const char *source; size_t srclen; int currentline; int linedefined; int lastlinedefined; unsigned char nups; unsigned char nparams; char isvararg; unsigned char extraargs; char istailcall; int ftransfer; int ntransfer; char short_src[LUA_IDSIZE]; };", body: "A structure used to carry different pieces of information about a function or an activation record." },
];

for (const t of CORE_TYPES) {
  writeCapi("core", t.name, {
    name: t.name,
    header: "lua.h",
    kind: "type",
    since: "0.1.0",
    stability: "stable",
    origin: "lua",
    signature: t.sig,
  }, t.body);
}

// ─── lua.h CONSTANTS ───

const CORE_CONSTS = [
  // Status codes
  { name: "LUA_OK", type: "int", value: 0, body: "Status code for no errors." },
  { name: "LUA_YIELD", type: "int", value: 1, body: "Status code indicating a coroutine yield." },
  { name: "LUA_ERRRUN", type: "int", value: 2, body: "Status code for a runtime error." },
  { name: "LUA_ERRSYNTAX", type: "int", value: 3, body: "Status code for a syntax error." },
  { name: "LUA_ERRMEM", type: "int", value: 4, body: "Status code for a memory allocation error." },
  { name: "LUA_ERRERR", type: "int", value: 5, body: "Status code for an error while running the message handler." },
  // Type tags
  { name: "LUA_TNONE", type: "int", value: -1, body: "Tag for no value." },
  { name: "LUA_TNIL", type: "int", value: 0, body: "Tag for nil values." },
  { name: "LUA_TBOOLEAN", type: "int", value: 1, body: "Tag for boolean values." },
  { name: "LUA_TLIGHTUSERDATA", type: "int", value: 2, body: "Tag for light userdata." },
  { name: "LUA_TNUMBER", type: "int", value: 3, body: "Tag for number values." },
  { name: "LUA_TSTRING", type: "int", value: 4, body: "Tag for string values." },
  { name: "LUA_TTABLE", type: "int", value: 5, body: "Tag for table values." },
  { name: "LUA_TFUNCTION", type: "int", value: 6, body: "Tag for function values." },
  { name: "LUA_TUSERDATA", type: "int", value: 7, body: "Tag for full userdata." },
  { name: "LUA_TTHREAD", type: "int", value: 8, body: "Tag for thread (coroutine) values." },
  { name: "LUA_TENUM", type: "int", value: 9, body: "Tag for enum values.", origin: "lus" },
  { name: "LUA_TVECTOR", type: "int", value: 10, body: "Tag for vector values.", origin: "lus" },
  { name: "LUA_NUMTYPES", type: "int", value: 11, body: "Total number of type tags." },
  // Pseudo-indices
  { name: "LUA_REGISTRYINDEX", type: "int", body: "Pseudo-index for the registry table." },
  { name: "LUA_MULTRET", type: "int", value: -1, body: "Option for multiple returns in `lua_call` and `lua_pcall`." },
  // Stack
  { name: "LUA_MINSTACK", type: "int", value: 20, body: "Minimum Lua stack size guaranteed to be available." },
  // Registry
  { name: "LUA_RIDX_GLOBALS", type: "int", value: 2, body: "Registry index for the global environment table." },
  { name: "LUA_RIDX_MAINTHREAD", type: "int", value: 3, body: "Registry index for the main thread." },
  // Arithmetic ops
  { name: "LUA_OPADD", type: "int", value: 0, body: "Code for addition in `lua_arith`." },
  { name: "LUA_OPSUB", type: "int", value: 1, body: "Code for subtraction in `lua_arith`." },
  { name: "LUA_OPMUL", type: "int", value: 2, body: "Code for multiplication in `lua_arith`." },
  { name: "LUA_OPMOD", type: "int", value: 3, body: "Code for modulo in `lua_arith`." },
  { name: "LUA_OPPOW", type: "int", value: 4, body: "Code for exponentiation in `lua_arith`." },
  { name: "LUA_OPDIV", type: "int", value: 5, body: "Code for float division in `lua_arith`." },
  { name: "LUA_OPIDIV", type: "int", value: 6, body: "Code for floor division in `lua_arith`." },
  { name: "LUA_OPBAND", type: "int", value: 7, body: "Code for bitwise AND in `lua_arith`." },
  { name: "LUA_OPBOR", type: "int", value: 8, body: "Code for bitwise OR in `lua_arith`." },
  { name: "LUA_OPBXOR", type: "int", value: 9, body: "Code for bitwise XOR in `lua_arith`." },
  { name: "LUA_OPSHL", type: "int", value: 10, body: "Code for left shift in `lua_arith`." },
  { name: "LUA_OPSHR", type: "int", value: 11, body: "Code for right shift in `lua_arith`." },
  { name: "LUA_OPUNM", type: "int", value: 12, body: "Code for unary minus in `lua_arith`." },
  { name: "LUA_OPBNOT", type: "int", value: 13, body: "Code for bitwise NOT in `lua_arith`." },
  // Comparison ops
  { name: "LUA_OPEQ", type: "int", value: 0, body: "Code for equality in `lua_compare`." },
  { name: "LUA_OPLT", type: "int", value: 1, body: "Code for less-than in `lua_compare`." },
  { name: "LUA_OPLE", type: "int", value: 2, body: "Code for less-or-equal in `lua_compare`." },
  // GC options
  { name: "LUA_GCSTOP", type: "int", value: 0, body: "GC option to stop the collector." },
  { name: "LUA_GCRESTART", type: "int", value: 1, body: "GC option to restart the collector." },
  { name: "LUA_GCCOLLECT", type: "int", value: 2, body: "GC option to perform a full collection cycle." },
  { name: "LUA_GCCOUNT", type: "int", value: 3, body: "GC option to return total memory in use (Kbytes)." },
  { name: "LUA_GCCOUNTB", type: "int", value: 4, body: "GC option to return remainder of memory in use (bytes)." },
  { name: "LUA_GCSTEP", type: "int", value: 5, body: "GC option to perform an incremental step." },
  { name: "LUA_GCISRUNNING", type: "int", value: 6, body: "GC option to check if the collector is running." },
  { name: "LUA_GCGEN", type: "int", value: 7, body: "GC option to switch to generational mode." },
  { name: "LUA_GCINC", type: "int", value: 8, body: "GC option to switch to incremental mode." },
  { name: "LUA_GCPARAM", type: "int", value: 9, body: "GC option to set/get a GC parameter." },
  // Hook events
  { name: "LUA_HOOKCALL", type: "int", value: 0, body: "Debug hook event for function calls." },
  { name: "LUA_HOOKRET", type: "int", value: 1, body: "Debug hook event for function returns." },
  { name: "LUA_HOOKLINE", type: "int", value: 2, body: "Debug hook event for new lines." },
  { name: "LUA_HOOKCOUNT", type: "int", value: 3, body: "Debug hook event for instruction counts." },
  { name: "LUA_HOOKTAILCALL", type: "int", value: 4, body: "Debug hook event for tail calls." },
  // Hook masks
  { name: "LUA_MASKCALL", type: "int", value: 1, body: "Mask for call hook events." },
  { name: "LUA_MASKRET", type: "int", value: 2, body: "Mask for return hook events." },
  { name: "LUA_MASKLINE", type: "int", value: 4, body: "Mask for line hook events." },
  { name: "LUA_MASKCOUNT", type: "int", value: 8, body: "Mask for count hook events." },
];

for (const c of CORE_CONSTS) {
  writeCapi("core", c.name, {
    name: c.name,
    header: "lua.h",
    kind: "constant",
    since: "0.1.0",
    stability: "stable",
    origin: c.origin || "lua",
    type: c.type,
    value: c.value,
  }, c.body);
}

// ─── lua.h FUNCTIONS ───

const CORE_FUNCS = [
  // State manipulation
  ["lua_newstate", "lua_State *lua_newstate (lua_Alloc f, void *ud, unsigned seed)", [{name:"f",type:"lua_Alloc"},{name:"ud",type:"void*"},{name:"seed",type:"unsigned"}], {returns:[{type:"lua_State*"}]}],
  ["lua_close", "void lua_close (lua_State *L)", [{name:"L",type:"lua_State*"}]],
  ["lua_newthread", "lua_State *lua_newthread (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"lua_State*"}]}],
  ["lua_closethread", "int lua_closethread (lua_State *L, lua_State *from)", [{name:"L",type:"lua_State*"},{name:"from",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_atpanic", "lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf)", [{name:"L",type:"lua_State*"},{name:"panicf",type:"lua_CFunction"}], {returns:[{type:"lua_CFunction"}]}],
  ["lua_version", "lua_Number lua_version (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"lua_Number"}]}],
  // Stack manipulation
  ["lua_absindex", "int lua_absindex (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_gettop", "int lua_gettop (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_settop", "void lua_settop (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_pushvalue", "void lua_pushvalue (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_rotate", "void lua_rotate (lua_State *L, int idx, int n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"int"}]],
  ["lua_copy", "void lua_copy (lua_State *L, int fromidx, int toidx)", [{name:"L",type:"lua_State*"},{name:"fromidx",type:"int"},{name:"toidx",type:"int"}]],
  ["lua_checkstack", "int lua_checkstack (lua_State *L, int n)", [{name:"L",type:"lua_State*"},{name:"n",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_xmove", "void lua_xmove (lua_State *from, lua_State *to, int n)", [{name:"from",type:"lua_State*"},{name:"to",type:"lua_State*"},{name:"n",type:"int"}]],
  // Access functions
  ["lua_isnumber", "int lua_isnumber (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_isstring", "int lua_isstring (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_iscfunction", "int lua_iscfunction (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_isinteger", "int lua_isinteger (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_isuserdata", "int lua_isuserdata (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_type", "int lua_type (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_typename", "const char *lua_typename (lua_State *L, int tp)", [{name:"L",type:"lua_State*"},{name:"tp",type:"int"}], {returns:[{type:"const char*"}]}],
  ["lua_tonumberx", "lua_Number lua_tonumberx (lua_State *L, int idx, int *isnum)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"isnum",type:"int*"}], {returns:[{type:"lua_Number"}]}],
  ["lua_tointegerx", "lua_Integer lua_tointegerx (lua_State *L, int idx, int *isnum)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"isnum",type:"int*"}], {returns:[{type:"lua_Integer"}]}],
  ["lua_toboolean", "int lua_toboolean (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_tolstring", "const char *lua_tolstring (lua_State *L, int idx, size_t *len)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"len",type:"size_t*"}], {returns:[{type:"const char*"}]}],
  ["lua_rawlen", "lua_Unsigned lua_rawlen (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"lua_Unsigned"}]}],
  ["lua_tocfunction", "lua_CFunction lua_tocfunction (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"lua_CFunction"}]}],
  ["lua_touserdata", "void *lua_touserdata (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"void*"}]}],
  ["lua_tothread", "lua_State *lua_tothread (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"lua_State*"}]}],
  ["lua_topointer", "const void *lua_topointer (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"const void*"}]}],
  // Arithmetic and comparison
  ["lua_arith", "void lua_arith (lua_State *L, int op)", [{name:"L",type:"lua_State*"},{name:"op",type:"int"}]],
  ["lua_rawequal", "int lua_rawequal (lua_State *L, int idx1, int idx2)", [{name:"L",type:"lua_State*"},{name:"idx1",type:"int"},{name:"idx2",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_compare", "int lua_compare (lua_State *L, int idx1, int idx2, int op)", [{name:"L",type:"lua_State*"},{name:"idx1",type:"int"},{name:"idx2",type:"int"},{name:"op",type:"int"}], {returns:[{type:"int"}]}],
  // Push functions
  ["lua_pushnil", "void lua_pushnil (lua_State *L)", [{name:"L",type:"lua_State*"}]],
  ["lua_pushnumber", "void lua_pushnumber (lua_State *L, lua_Number n)", [{name:"L",type:"lua_State*"},{name:"n",type:"lua_Number"}]],
  ["lua_pushinteger", "void lua_pushinteger (lua_State *L, lua_Integer n)", [{name:"L",type:"lua_State*"},{name:"n",type:"lua_Integer"}]],
  ["lua_pushlstring", "const char *lua_pushlstring (lua_State *L, const char *s, size_t len)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"},{name:"len",type:"size_t"}], {returns:[{type:"const char*"}]}],
  ["lua_pushstring", "const char *lua_pushstring (lua_State *L, const char *s)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"}], {returns:[{type:"const char*"}]}],
  ["lua_pushfstring", "const char *lua_pushfstring (lua_State *L, const char *fmt, ...)", [{name:"L",type:"lua_State*"},{name:"fmt",type:"const char*"}], {returns:[{type:"const char*"}]}],
  ["lua_pushcclosure", "void lua_pushcclosure (lua_State *L, lua_CFunction fn, int n)", [{name:"L",type:"lua_State*"},{name:"fn",type:"lua_CFunction"},{name:"n",type:"int"}]],
  ["lua_pushboolean", "void lua_pushboolean (lua_State *L, int b)", [{name:"L",type:"lua_State*"},{name:"b",type:"int"}]],
  ["lua_pushlightuserdata", "void lua_pushlightuserdata (lua_State *L, void *p)", [{name:"L",type:"lua_State*"},{name:"p",type:"void*"}]],
  ["lua_pushthread", "int lua_pushthread (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_pushenum", "void lua_pushenum (lua_State *L, int npairs)", [{name:"L",type:"lua_State*"},{name:"npairs",type:"int"}], {origin:"lus"}],
  ["lua_pushexternalstring", "const char *lua_pushexternalstring (lua_State *L, const char *s, size_t len, lua_Alloc falloc, void *ud)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"},{name:"len",type:"size_t"},{name:"falloc",type:"lua_Alloc"},{name:"ud",type:"void*"}], {returns:[{type:"const char*"}]}],
  ["lua_pushvfstring", "const char *lua_pushvfstring (lua_State *L, const char *fmt, va_list argp)", [{name:"L",type:"lua_State*"},{name:"fmt",type:"const char*"},{name:"argp",type:"va_list"}], {returns:[{type:"const char*"}]}],
  // Get functions
  ["lua_getglobal", "int lua_getglobal (lua_State *L, const char *name)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"}], {returns:[{type:"int"}]}],
  ["lua_gettable", "int lua_gettable (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_getfield", "int lua_getfield (lua_State *L, int idx, const char *k)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"k",type:"const char*"}], {returns:[{type:"int"}]}],
  ["lua_geti", "int lua_geti (lua_State *L, int idx, lua_Integer n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"lua_Integer"}], {returns:[{type:"int"}]}],
  ["lua_rawget", "int lua_rawget (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_rawgeti", "int lua_rawgeti (lua_State *L, int idx, lua_Integer n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"lua_Integer"}], {returns:[{type:"int"}]}],
  ["lua_rawgetp", "int lua_rawgetp (lua_State *L, int idx, const void *p)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"p",type:"const void*"}], {returns:[{type:"int"}]}],
  ["lua_createtable", "void lua_createtable (lua_State *L, int narr, int nrec)", [{name:"L",type:"lua_State*"},{name:"narr",type:"int"},{name:"nrec",type:"int"}]],
  ["lua_newuserdatauv", "void *lua_newuserdatauv (lua_State *L, size_t sz, int nuvalue)", [{name:"L",type:"lua_State*"},{name:"sz",type:"size_t"},{name:"nuvalue",type:"int"}], {returns:[{type:"void*"}]}],
  ["lua_getmetatable", "int lua_getmetatable (lua_State *L, int objindex)", [{name:"L",type:"lua_State*"},{name:"objindex",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_getiuservalue", "int lua_getiuservalue (lua_State *L, int idx, int n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"int"}], {returns:[{type:"int"}]}],
  // Set functions
  ["lua_setglobal", "void lua_setglobal (lua_State *L, const char *name)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"}]],
  ["lua_settable", "void lua_settable (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_setfield", "void lua_setfield (lua_State *L, int idx, const char *k)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"k",type:"const char*"}]],
  ["lua_seti", "void lua_seti (lua_State *L, int idx, lua_Integer n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"lua_Integer"}]],
  ["lua_rawset", "void lua_rawset (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_rawseti", "void lua_rawseti (lua_State *L, int idx, lua_Integer n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"lua_Integer"}]],
  ["lua_rawsetp", "void lua_rawsetp (lua_State *L, int idx, const void *p)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"p",type:"const void*"}]],
  ["lua_setmetatable", "int lua_setmetatable (lua_State *L, int objindex)", [{name:"L",type:"lua_State*"},{name:"objindex",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_setiuservalue", "int lua_setiuservalue (lua_State *L, int idx, int n)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"n",type:"int"}], {returns:[{type:"int"}]}],
  // Load and call
  ["lua_callk", "void lua_callk (lua_State *L, int nargs, int nresults, lua_KContext ctx, lua_KFunction k)", [{name:"L",type:"lua_State*"},{name:"nargs",type:"int"},{name:"nresults",type:"int"},{name:"ctx",type:"lua_KContext"},{name:"k",type:"lua_KFunction"}]],
  ["lua_pcallk", "int lua_pcallk (lua_State *L, int nargs, int nresults, int errfunc, lua_KContext ctx, lua_KFunction k)", [{name:"L",type:"lua_State*"},{name:"nargs",type:"int"},{name:"nresults",type:"int"},{name:"errfunc",type:"int"},{name:"ctx",type:"lua_KContext"},{name:"k",type:"lua_KFunction"}], {returns:[{type:"int"}], stability:"deprecated", body: "**Deprecated.** Use `CPROTECT_BEGIN`/`CPROTECT_END` macros instead."}],
  ["lua_load", "int lua_load (lua_State *L, lua_Reader reader, void *dt, const char *chunkname, const char *mode)", [{name:"L",type:"lua_State*"},{name:"reader",type:"lua_Reader"},{name:"dt",type:"void*"},{name:"chunkname",type:"const char*"},{name:"mode",type:"const char*"}], {returns:[{type:"int"}]}],
  ["lua_dump", "int lua_dump (lua_State *L, lua_Writer writer, void *data, int strip)", [{name:"L",type:"lua_State*"},{name:"writer",type:"lua_Writer"},{name:"data",type:"void*"},{name:"strip",type:"int"}], {returns:[{type:"int"}]}],
  // Coroutine
  ["lua_yieldk", "int lua_yieldk (lua_State *L, int nresults, lua_KContext ctx, lua_KFunction k)", [{name:"L",type:"lua_State*"},{name:"nresults",type:"int"},{name:"ctx",type:"lua_KContext"},{name:"k",type:"lua_KFunction"}], {returns:[{type:"int"}]}],
  ["lua_resume", "int lua_resume (lua_State *L, lua_State *from, int narg, int *nres)", [{name:"L",type:"lua_State*"},{name:"from",type:"lua_State*"},{name:"narg",type:"int"},{name:"nres",type:"int*"}], {returns:[{type:"int"}]}],
  ["lua_status", "int lua_status (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_isyieldable", "int lua_isyieldable (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  // Warning
  ["lua_setwarnf", "void lua_setwarnf (lua_State *L, lua_WarnFunction f, void *ud)", [{name:"L",type:"lua_State*"},{name:"f",type:"lua_WarnFunction"},{name:"ud",type:"void*"}]],
  ["lua_warning", "void lua_warning (lua_State *L, const char *msg, int tocont)", [{name:"L",type:"lua_State*"},{name:"msg",type:"const char*"},{name:"tocont",type:"int"}]],
  // GC
  ["lua_gc", "int lua_gc (lua_State *L, int what, ...)", [{name:"L",type:"lua_State*"},{name:"what",type:"int"}], {returns:[{type:"int"}]}],
  // Misc
  ["lua_error", "int lua_error (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_next", "int lua_next (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"int"}]}],
  ["lua_concat", "void lua_concat (lua_State *L, int n)", [{name:"L",type:"lua_State*"},{name:"n",type:"int"}]],
  ["lua_len", "void lua_len (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_numbertocstring", "unsigned lua_numbertocstring (lua_State *L, int idx, char *buff)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"buff",type:"char*"}], {returns:[{type:"unsigned"}]}],
  ["lua_stringtonumber", "size_t lua_stringtonumber (lua_State *L, const char *s)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"}], {returns:[{type:"size_t"}]}],
  ["lua_getallocf", "lua_Alloc lua_getallocf (lua_State *L, void **ud)", [{name:"L",type:"lua_State*"},{name:"ud",type:"void**"}], {returns:[{type:"lua_Alloc"}]}],
  ["lua_setallocf", "void lua_setallocf (lua_State *L, lua_Alloc f, void *ud)", [{name:"L",type:"lua_State*"},{name:"f",type:"lua_Alloc"},{name:"ud",type:"void*"}]],
  ["lua_toclose", "void lua_toclose (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  ["lua_closeslot", "void lua_closeslot (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}]],
  // Debug
  ["lua_getstack", "int lua_getstack (lua_State *L, int level, lua_Debug *ar)", [{name:"L",type:"lua_State*"},{name:"level",type:"int"},{name:"ar",type:"lua_Debug*"}], {returns:[{type:"int"}]}],
  ["lua_getinfo", "int lua_getinfo (lua_State *L, const char *what, lua_Debug *ar)", [{name:"L",type:"lua_State*"},{name:"what",type:"const char*"},{name:"ar",type:"lua_Debug*"}], {returns:[{type:"int"}]}],
  ["lua_getlocal", "const char *lua_getlocal (lua_State *L, const lua_Debug *ar, int n)", [{name:"L",type:"lua_State*"},{name:"ar",type:"const lua_Debug*"},{name:"n",type:"int"}], {returns:[{type:"const char*"}]}],
  ["lua_setlocal", "const char *lua_setlocal (lua_State *L, const lua_Debug *ar, int n)", [{name:"L",type:"lua_State*"},{name:"ar",type:"const lua_Debug*"},{name:"n",type:"int"}], {returns:[{type:"const char*"}]}],
  ["lua_getupvalue", "const char *lua_getupvalue (lua_State *L, int funcindex, int n)", [{name:"L",type:"lua_State*"},{name:"funcindex",type:"int"},{name:"n",type:"int"}], {returns:[{type:"const char*"}]}],
  ["lua_setupvalue", "const char *lua_setupvalue (lua_State *L, int funcindex, int n)", [{name:"L",type:"lua_State*"},{name:"funcindex",type:"int"},{name:"n",type:"int"}], {returns:[{type:"const char*"}]}],
  ["lua_upvalueid", "void *lua_upvalueid (lua_State *L, int fidx, int n)", [{name:"L",type:"lua_State*"},{name:"fidx",type:"int"},{name:"n",type:"int"}], {returns:[{type:"void*"}]}],
  ["lua_upvaluejoin", "void lua_upvaluejoin (lua_State *L, int fidx1, int n1, int fidx2, int n2)", [{name:"L",type:"lua_State*"},{name:"fidx1",type:"int"},{name:"n1",type:"int"},{name:"fidx2",type:"int"},{name:"n2",type:"int"}]],
  ["lua_sethook", "void lua_sethook (lua_State *L, lua_Hook func, int mask, int count)", [{name:"L",type:"lua_State*"},{name:"func",type:"lua_Hook"},{name:"mask",type:"int"},{name:"count",type:"int"}]],
  ["lua_gethook", "lua_Hook lua_gethook (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"lua_Hook"}]}],
  ["lua_gethookmask", "int lua_gethookmask (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
  ["lua_gethookcount", "int lua_gethookcount (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"int"}]}],
];

for (const [name, sig, params, opts] of CORE_FUNCS) {
  coreFunc(name, sig, params, opts || {});
}

// ─── lua.h MACROS ───

const CORE_MACROS = [
  { name: "lua_pop", sig: "#define lua_pop(L,n) lua_settop(L, -(n)-1)", body: "Pops `n` elements from the stack." },
  { name: "lua_newtable", sig: "#define lua_newtable(L) lua_createtable(L, 0, 0)", body: "Creates a new empty table and pushes it onto the stack." },
  { name: "lua_register", sig: "#define lua_register(L,n,f) (lua_pushcfunction(L,(f)), lua_setglobal(L,(n)))", body: "Sets the C function `f` as the new value of global `n`." },
  { name: "lua_pushcfunction", sig: "#define lua_pushcfunction(L,f) lua_pushcclosure(L,(f),0)", body: "Pushes a C function onto the stack (macro for `lua_pushcclosure` with 0 upvalues)." },
  { name: "lua_isfunction", sig: "#define lua_isfunction(L,n) (lua_type(L,(n)) == LUA_TFUNCTION)", body: "Returns 1 if the value at the given index is a function." },
  { name: "lua_istable", sig: "#define lua_istable(L,n) (lua_type(L,(n)) == LUA_TTABLE)", body: "Returns 1 if the value at the given index is a table." },
  { name: "lua_islightuserdata", sig: "#define lua_islightuserdata(L,n) (lua_type(L,(n)) == LUA_TLIGHTUSERDATA)", body: "Returns 1 if the value at the given index is a light userdata." },
  { name: "lua_isnil", sig: "#define lua_isnil(L,n) (lua_type(L,(n)) == LUA_TNIL)", body: "Returns 1 if the value at the given index is nil." },
  { name: "lua_isboolean", sig: "#define lua_isboolean(L,n) (lua_type(L,(n)) == LUA_TBOOLEAN)", body: "Returns 1 if the value at the given index is a boolean." },
  { name: "lua_isthread", sig: "#define lua_isthread(L,n) (lua_type(L,(n)) == LUA_TTHREAD)", body: "Returns 1 if the value at the given index is a thread." },
  { name: "lua_isenum", sig: "#define lua_isenum(L,n) (lua_type(L,(n)) == LUA_TENUM)", body: "Returns 1 if the value at the given index is an enum.", origin: "lus" },
  { name: "lua_isvector", sig: "#define lua_isvector(L,n) (lua_type(L,(n)) == LUA_TVECTOR)", body: "Returns 1 if the value at the given index is a vector.", origin: "lus" },
  { name: "lua_isnone", sig: "#define lua_isnone(L,n) (lua_type(L,(n)) == LUA_TNONE)", body: "Returns 1 if the given index is not valid." },
  { name: "lua_isnoneornil", sig: "#define lua_isnoneornil(L,n) (lua_type(L,(n)) <= 0)", body: "Returns 1 if the given index is not valid or the value is nil." },
  { name: "lua_pushliteral", sig: '#define lua_pushliteral(L,s) lua_pushstring(L, "" s)', body: "Pushes a literal string onto the stack." },
  { name: "lua_pushglobaltable", sig: "#define lua_pushglobaltable(L) ((void)lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS))", body: "Pushes the global environment table onto the stack." },
  { name: "lua_tostring", sig: "#define lua_tostring(L,i) lua_tolstring(L,(i),NULL)", body: "Equivalent to `lua_tolstring` with `len` equal to NULL." },
  { name: "lua_insert", sig: "#define lua_insert(L,idx) lua_rotate(L,(idx),1)", body: "Moves the top element into the given valid index, shifting up elements above." },
  { name: "lua_remove", sig: "#define lua_remove(L,idx) (lua_rotate(L,(idx),-1), lua_pop(L,1))", body: "Removes the element at the given valid index, shifting down elements above." },
  { name: "lua_replace", sig: "#define lua_replace(L,idx) (lua_copy(L,-1,(idx)), lua_pop(L,1))", body: "Moves the top element into the given valid index without shifting." },
  { name: "lua_call", sig: "#define lua_call(L,n,r) lua_callk(L,(n),(r),0,NULL)", body: "Calls a function (macro for `lua_callk` with no continuation)." },
  { name: "lua_pcall", sig: "#define lua_pcall(L,n,r,f) lua_pcallk(L,(n),(r),(f),0,NULL)", body: "**Deprecated.** Calls a function in protected mode.", stability: "deprecated" },
  { name: "lua_yield", sig: "#define lua_yield(L,n) lua_yieldk(L,(n),0,NULL)", body: "Yields a coroutine (macro for `lua_yieldk` with no continuation)." },
  { name: "lua_tonumber", sig: "#define lua_tonumber(L,i) lua_tonumberx(L,(i),NULL)", body: "Converts the value at the given index to a `lua_Number`." },
  { name: "lua_tointeger", sig: "#define lua_tointeger(L,i) lua_tointegerx(L,(i),NULL)", body: "Converts the value at the given index to a `lua_Integer`." },
  { name: "lua_getextraspace", sig: "#define lua_getextraspace(L) ((void *)((char *)(L) - LUA_EXTRASPACE))", body: "Returns a pointer to a raw memory area associated with the given Lua state." },
  { name: "lua_newuserdata", sig: "#define lua_newuserdata(L,s) lua_newuserdatauv(L,s,1)", body: "Compatibility macro. Creates a new userdata with one user value." },
  { name: "lua_getuservalue", sig: "#define lua_getuservalue(L,idx) lua_getiuservalue(L,idx,1)", body: "Compatibility macro. Gets the first user value of a userdata." },
  { name: "lua_setuservalue", sig: "#define lua_setuservalue(L,idx) lua_setiuservalue(L,idx,1)", body: "Compatibility macro. Sets the first user value of a userdata." },
  { name: "lua_upvalueindex", sig: "#define lua_upvalueindex(i) (LUA_REGISTRYINDEX - (i))", body: "Returns the pseudo-index for the `i`-th upvalue of a C closure." },
];

for (const m of CORE_MACROS) {
  writeCapi("core", m.name, {
    name: m.name,
    header: "lua.h",
    kind: "macro",
    since: "0.1.0",
    stability: m.stability || "stable",
    origin: m.origin || "lua",
    signature: m.sig,
  }, m.body);
}

// ─── lauxlib.h FUNCTIONS ───

const AUX_FUNCS = [
  ["luaL_checkversion_", "void luaL_checkversion_ (lua_State *L, lua_Number ver, size_t sz)", [{name:"L",type:"lua_State*"},{name:"ver",type:"lua_Number"},{name:"sz",type:"size_t"}]],
  ["luaL_getmetafield", "int luaL_getmetafield (lua_State *L, int obj, const char *e)", [{name:"L",type:"lua_State*"},{name:"obj",type:"int"},{name:"e",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_callmeta", "int luaL_callmeta (lua_State *L, int obj, const char *e)", [{name:"L",type:"lua_State*"},{name:"obj",type:"int"},{name:"e",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_tolstring", "const char *luaL_tolstring (lua_State *L, int idx, size_t *len)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"len",type:"size_t*"}], {returns:[{type:"const char*"}]}],
  ["luaL_argerror", "int luaL_argerror (lua_State *L, int arg, const char *extramsg)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"extramsg",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_typeerror", "int luaL_typeerror (lua_State *L, int arg, const char *tname)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"tname",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_checklstring", "const char *luaL_checklstring (lua_State *L, int arg, size_t *l)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"l",type:"size_t*"}], {returns:[{type:"const char*"}]}],
  ["luaL_optlstring", "const char *luaL_optlstring (lua_State *L, int arg, const char *def, size_t *l)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"def",type:"const char*"},{name:"l",type:"size_t*"}], {returns:[{type:"const char*"}]}],
  ["luaL_checknumber", "lua_Number luaL_checknumber (lua_State *L, int arg)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"}], {returns:[{type:"lua_Number"}]}],
  ["luaL_optnumber", "lua_Number luaL_optnumber (lua_State *L, int arg, lua_Number def)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"def",type:"lua_Number"}], {returns:[{type:"lua_Number"}]}],
  ["luaL_checkinteger", "lua_Integer luaL_checkinteger (lua_State *L, int arg)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"}], {returns:[{type:"lua_Integer"}]}],
  ["luaL_optinteger", "lua_Integer luaL_optinteger (lua_State *L, int arg, lua_Integer def)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"def",type:"lua_Integer"}], {returns:[{type:"lua_Integer"}]}],
  ["luaL_checkstack", "void luaL_checkstack (lua_State *L, int sz, const char *msg)", [{name:"L",type:"lua_State*"},{name:"sz",type:"int"},{name:"msg",type:"const char*"}]],
  ["luaL_checktype", "void luaL_checktype (lua_State *L, int arg, int t)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"t",type:"int"}]],
  ["luaL_checkany", "void luaL_checkany (lua_State *L, int arg)", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"}]],
  ["luaL_newmetatable", "int luaL_newmetatable (lua_State *L, const char *tname)", [{name:"L",type:"lua_State*"},{name:"tname",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_setmetatable", "void luaL_setmetatable (lua_State *L, const char *tname)", [{name:"L",type:"lua_State*"},{name:"tname",type:"const char*"}]],
  ["luaL_testudata", "void *luaL_testudata (lua_State *L, int ud, const char *tname)", [{name:"L",type:"lua_State*"},{name:"ud",type:"int"},{name:"tname",type:"const char*"}], {returns:[{type:"void*"}]}],
  ["luaL_checkudata", "void *luaL_checkudata (lua_State *L, int ud, const char *tname)", [{name:"L",type:"lua_State*"},{name:"ud",type:"int"},{name:"tname",type:"const char*"}], {returns:[{type:"void*"}]}],
  ["luaL_where", "void luaL_where (lua_State *L, int lvl)", [{name:"L",type:"lua_State*"},{name:"lvl",type:"int"}]],
  ["luaL_error", "int luaL_error (lua_State *L, const char *fmt, ...)", [{name:"L",type:"lua_State*"},{name:"fmt",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_checkoption", "int luaL_checkoption (lua_State *L, int arg, const char *def, const char *const lst[])", [{name:"L",type:"lua_State*"},{name:"arg",type:"int"},{name:"def",type:"const char*"},{name:"lst",type:"const char *const[]"}], {returns:[{type:"int"}]}],
  ["luaL_fileresult", "int luaL_fileresult (lua_State *L, int stat, const char *fname)", [{name:"L",type:"lua_State*"},{name:"stat",type:"int"},{name:"fname",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_execresult", "int luaL_execresult (lua_State *L, int stat)", [{name:"L",type:"lua_State*"},{name:"stat",type:"int"}], {returns:[{type:"int"}]}],
  ["luaL_ref", "int luaL_ref (lua_State *L, int t)", [{name:"L",type:"lua_State*"},{name:"t",type:"int"}], {returns:[{type:"int"}]}],
  ["luaL_unref", "void luaL_unref (lua_State *L, int t, int ref)", [{name:"L",type:"lua_State*"},{name:"t",type:"int"},{name:"ref",type:"int"}]],
  ["luaL_loadfilex", "int luaL_loadfilex (lua_State *L, const char *filename, const char *mode)", [{name:"L",type:"lua_State*"},{name:"filename",type:"const char*"},{name:"mode",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_loadbufferx", "int luaL_loadbufferx (lua_State *L, const char *buff, size_t sz, const char *name, const char *mode)", [{name:"L",type:"lua_State*"},{name:"buff",type:"const char*"},{name:"sz",type:"size_t"},{name:"name",type:"const char*"},{name:"mode",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_loadstring", "int luaL_loadstring (lua_State *L, const char *s)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_newstate", "lua_State *luaL_newstate (void)", [], {returns:[{type:"lua_State*"}]}],
  ["luaL_makeseed", "unsigned luaL_makeseed (lua_State *L)", [{name:"L",type:"lua_State*"}], {returns:[{type:"unsigned"}]}],
  ["luaL_len", "lua_Integer luaL_len (lua_State *L, int idx)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"}], {returns:[{type:"lua_Integer"}]}],
  ["luaL_addgsub", "void luaL_addgsub (luaL_Buffer *b, const char *s, const char *p, const char *r)", [{name:"b",type:"luaL_Buffer*"},{name:"s",type:"const char*"},{name:"p",type:"const char*"},{name:"r",type:"const char*"}]],
  ["luaL_gsub", "const char *luaL_gsub (lua_State *L, const char *s, const char *p, const char *r)", [{name:"L",type:"lua_State*"},{name:"s",type:"const char*"},{name:"p",type:"const char*"},{name:"r",type:"const char*"}], {returns:[{type:"const char*"}]}],
  ["luaL_setfuncs", "void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup)", [{name:"L",type:"lua_State*"},{name:"l",type:"const luaL_Reg*"},{name:"nup",type:"int"}]],
  ["luaL_getsubtable", "int luaL_getsubtable (lua_State *L, int idx, const char *fname)", [{name:"L",type:"lua_State*"},{name:"idx",type:"int"},{name:"fname",type:"const char*"}], {returns:[{type:"int"}]}],
  ["luaL_traceback", "void luaL_traceback (lua_State *L, lua_State *L1, const char *msg, int level)", [{name:"L",type:"lua_State*"},{name:"L1",type:"lua_State*"},{name:"msg",type:"const char*"},{name:"level",type:"int"}]],
  ["luaL_requiref", "void luaL_requiref (lua_State *L, const char *modname, lua_CFunction openf, int glb)", [{name:"L",type:"lua_State*"},{name:"modname",type:"const char*"},{name:"openf",type:"lua_CFunction"},{name:"glb",type:"int"}]],
  // Buffer functions
  ["luaL_buffinit", "void luaL_buffinit (lua_State *L, luaL_Buffer *B)", [{name:"L",type:"lua_State*"},{name:"B",type:"luaL_Buffer*"}]],
  ["luaL_prepbuffsize", "char *luaL_prepbuffsize (luaL_Buffer *B, size_t sz)", [{name:"B",type:"luaL_Buffer*"},{name:"sz",type:"size_t"}], {returns:[{type:"char*"}]}],
  ["luaL_addlstring", "void luaL_addlstring (luaL_Buffer *B, const char *s, size_t l)", [{name:"B",type:"luaL_Buffer*"},{name:"s",type:"const char*"},{name:"l",type:"size_t"}]],
  ["luaL_addstring", "void luaL_addstring (luaL_Buffer *B, const char *s)", [{name:"B",type:"luaL_Buffer*"},{name:"s",type:"const char*"}]],
  ["luaL_addvalue", "void luaL_addvalue (luaL_Buffer *B)", [{name:"B",type:"luaL_Buffer*"}]],
  ["luaL_pushresult", "void luaL_pushresult (luaL_Buffer *B)", [{name:"B",type:"luaL_Buffer*"}]],
  ["luaL_pushresultsize", "void luaL_pushresultsize (luaL_Buffer *B, size_t sz)", [{name:"B",type:"luaL_Buffer*"},{name:"sz",type:"size_t"}]],
  ["luaL_buffinitsize", "char *luaL_buffinitsize (lua_State *L, luaL_Buffer *B, size_t sz)", [{name:"L",type:"lua_State*"},{name:"B",type:"luaL_Buffer*"},{name:"sz",type:"size_t"}], {returns:[{type:"char*"}]}],
  ["luaL_alloc", "void *luaL_alloc (void *ud, void *ptr, size_t osize, size_t nsize)", [{name:"ud",type:"void*"},{name:"ptr",type:"void*"},{name:"osize",type:"size_t"},{name:"nsize",type:"size_t"}], {returns:[{type:"void*"}]}],
];

for (const [name, sig, params, opts] of AUX_FUNCS) {
  auxFunc(name, sig, params, opts || {});
}

// ─── lauxlib.h TYPES ───

const AUX_TYPES = [
  { name: "luaL_Reg", sig: "typedef struct luaL_Reg { const char *name; lua_CFunction func; } luaL_Reg;", body: "Type for arrays of functions to be registered with `luaL_setfuncs`." },
  { name: "luaL_Buffer", sig: "struct luaL_Buffer { char *b; size_t size; size_t n; lua_State *L; };", body: "Type for a string buffer. A string buffer allows C code to build Lua strings piecemeal." },
  { name: "luaL_Stream", sig: "typedef struct luaL_Stream { FILE *f; lua_CFunction closef; } luaL_Stream;", body: "The internal structure used by the standard I/O library for file handles." },
];

for (const t of AUX_TYPES) {
  writeCapi("auxiliary", t.name, {
    name: t.name,
    header: "lauxlib.h",
    kind: "type",
    since: "0.1.0",
    stability: "stable",
    origin: "lua",
    signature: t.sig,
  }, t.body);
}

// ─── lauxlib.h CONSTANTS ───

const AUX_CONSTS = [
  { name: "LUA_ERRFILE", type: "int", value: 6, body: "Error code for file-related errors in `luaL_loadfile`." },
  { name: "LUA_NOREF", type: "int", value: -2, body: "Special reference value representing no reference." },
  { name: "LUA_REFNIL", type: "int", value: -1, body: "Special reference value representing a reference to nil." },
  { name: "LUA_FILEHANDLE", type: "string", body: "Metatable name for file handles." },
  { name: "LUAL_NUMSIZES", type: "int", body: "Encodes the size of integers and floats for version checking." },
  { name: "LUAL_BUFFERSIZE", type: "int", body: "The initial buffer size used by the buffer system." },
];

for (const c of AUX_CONSTS) {
  writeCapi("auxiliary", c.name, {
    name: c.name,
    header: "lauxlib.h",
    kind: "constant",
    since: "0.1.0",
    stability: "stable",
    origin: "lua",
    type: c.type,
    value: c.value,
  }, c.body);
}

// ─── lauxlib.h MACROS ───

const AUX_MACROS = [
  { name: "luaL_checkversion", sig: "#define luaL_checkversion(L) luaL_checkversion_(L, LUA_VERSION_NUM, LUAL_NUMSIZES)", body: "Checks that the code making the call and the Lua library being called are using the same version of Lua and compatible numeric types." },
  { name: "luaL_loadfile", sig: '#define luaL_loadfile(L,f) luaL_loadfilex(L,f,NULL)', body: "Loads a file as a Lua chunk (macro for `luaL_loadfilex` with NULL mode)." },
  { name: "luaL_loadbuffer", sig: "#define luaL_loadbuffer(L,s,sz,n) luaL_loadbufferx(L,s,sz,n,NULL)", body: "Loads a buffer as a Lua chunk." },
  { name: "luaL_newlib", sig: "#define luaL_newlib(L,l) (luaL_checkversion(L), luaL_newlibtable(L,l), luaL_setfuncs(L,l,0))", body: "Creates a new table and registers the functions in `l` into it." },
  { name: "luaL_newlibtable", sig: "#define luaL_newlibtable(L,l) lua_createtable(L, 0, sizeof(l)/sizeof((l)[0]) - 1)", body: "Creates a table with a size hint for the number of entries in `l`." },
  { name: "luaL_argcheck", sig: '#define luaL_argcheck(L,cond,arg,extramsg)', body: "Checks whether `cond` is true. If not, raises an argument error." },
  { name: "luaL_argexpected", sig: "#define luaL_argexpected(L,cond,arg,tname)", body: "Checks whether `cond` is true. If not, raises a type error." },
  { name: "luaL_checkstring", sig: "#define luaL_checkstring(L,n) (luaL_checklstring(L,(n),NULL))", body: "Checks whether the function argument `n` is a string and returns it." },
  { name: "luaL_optstring", sig: "#define luaL_optstring(L,n,d) (luaL_optlstring(L,(n),(d),NULL))", body: "If the function argument `n` is a string, returns it; otherwise returns `d`." },
  { name: "luaL_typename", sig: "#define luaL_typename(L,i) lua_typename(L, lua_type(L,(i)))", body: "Returns the name of the type of the value at the given index." },
  { name: "luaL_dofile", sig: '#define luaL_dofile(L,fn) (luaL_loadfile(L,fn) || lua_pcall(L,0,LUA_MULTRET,0))', body: "Loads and runs the given file." },
  { name: "luaL_dostring", sig: '#define luaL_dostring(L,s) (luaL_loadstring(L,s) || lua_pcall(L,0,LUA_MULTRET,0))', body: "Loads and runs the given string." },
  { name: "luaL_getmetatable", sig: '#define luaL_getmetatable(L,n) (lua_getfield(L,LUA_REGISTRYINDEX,(n)))', body: "Pushes onto the stack the metatable associated with the name `n` in the registry." },
  { name: "luaL_pushfail", sig: "#define luaL_pushfail(L) lua_pushnil(L)", body: "Pushes the **fail** value onto the stack." },
  { name: "luaL_addchar", sig: "#define luaL_addchar(B,c)", body: "Adds the byte `c` to the buffer `B`." },
  { name: "luaL_addsize", sig: "#define luaL_addsize(B,s) ((B)->n += (s))", body: "Adds to the buffer a string of length `s` previously copied to the buffer area." },
  { name: "luaL_buffsub", sig: "#define luaL_buffsub(B,s) ((B)->n -= (s))", body: "Removes `s` bytes from the buffer." },
  { name: "luaL_bufflen", sig: "#define luaL_bufflen(bf) ((bf)->n)", body: "Returns the current length of the buffer content." },
  { name: "luaL_buffaddr", sig: "#define luaL_buffaddr(bf) ((bf)->b)", body: "Returns the address of the buffer content." },
  { name: "luaL_prepbuffer", sig: "#define luaL_prepbuffer(B) luaL_prepbuffsize(B, LUAL_BUFFERSIZE)", body: "Equivalent to `luaL_prepbuffsize` with `LUAL_BUFFERSIZE`." },
];

for (const m of AUX_MACROS) {
  writeCapi("auxiliary", m.name, {
    name: m.name,
    header: "lauxlib.h",
    kind: "macro",
    since: "0.1.0",
    stability: "stable",
    origin: "lua",
    signature: m.sig,
  }, m.body);
}

// ─── lualib.h — Library openers ───

const LIBRARY_OPENERS = [
  { name: "luaopen_base", lib: "base" },
  { name: "luaopen_package", lib: "package" },
  { name: "luaopen_coroutine", lib: "coroutine" },
  { name: "luaopen_debug", lib: "debug" },
  { name: "luaopen_io", lib: "io" },
  { name: "luaopen_math", lib: "math" },
  { name: "luaopen_os", lib: "os" },
  { name: "luaopen_string", lib: "string" },
  { name: "luaopen_table", lib: "table" },
  { name: "luaopen_utf8", lib: "utf8" },
  { name: "luaopen_fs", lib: "fs", origin: "lus" },
  { name: "luaopen_network", lib: "network", origin: "lus" },
  { name: "luaopen_worker", lib: "worker", origin: "lus" },
  { name: "luaopen_vector", lib: "vector", origin: "lus" },
  { name: "luaopen_json", lib: "json", origin: "lus" },
];

for (const o of LIBRARY_OPENERS) {
  writeCapi("library", o.name, {
    name: o.name,
    header: "lualib.h",
    kind: "function",
    since: "0.1.0",
    stability: "stable",
    origin: o.origin || "lua",
    signature: `int ${o.name} (lua_State *L)`,
    params: [{name: "L", type: "lua_State*"}],
    returns: [{type: "int"}],
  }, `Opens the ${o.lib} library. Called automatically by \`luaL_openlibs\`.`);
}

// luaL_openselectedlibs
writeCapi("library", "luaL_openselectedlibs", {
  name: "luaL_openselectedlibs",
  header: "lualib.h",
  kind: "function",
  since: "0.1.0",
  stability: "stable",
  origin: "lua",
  signature: "void luaL_openselectedlibs (lua_State *L, int load, int preload)",
  params: [{name: "L", type: "lua_State*"}, {name: "load", type: "int"}, {name: "preload", type: "int"}],
}, "Opens selected standard libraries. The `load` and `preload` bitmasks control which libraries to open or preload.");

// luaL_openlibs macro
writeCapi("library", "luaL_openlibs", {
  name: "luaL_openlibs",
  header: "lualib.h",
  kind: "macro",
  since: "0.1.0",
  stability: "stable",
  origin: "lua",
  signature: "#define luaL_openlibs(L) luaL_openselectedlibs(L, ~0, 0)",
}, "Opens all standard libraries.");

// Library bitmask constants
const LIB_CONSTS = [
  { name: "LUA_GLIBK", value: 1, body: "Bitmask for the base library." },
  { name: "LUA_LOADLIBK", value: 2, body: "Bitmask for the package library." },
  { name: "LUA_COLIBK", value: 4, body: "Bitmask for the coroutine library." },
  { name: "LUA_DBLIBK", value: 8, body: "Bitmask for the debug library." },
  { name: "LUA_IOLIBK", value: 16, body: "Bitmask for the io library." },
  { name: "LUA_MATHLIBK", value: 32, body: "Bitmask for the math library." },
  { name: "LUA_OSLIBK", value: 64, body: "Bitmask for the os library." },
  { name: "LUA_STRLIBK", value: 128, body: "Bitmask for the string library." },
  { name: "LUA_TABLIBK", value: 256, body: "Bitmask for the table library." },
  { name: "LUA_UTF8LIBK", value: 512, body: "Bitmask for the utf8 library." },
  { name: "LUA_FSLIBK", value: 1024, body: "Bitmask for the fs library.", origin: "lus" },
  { name: "LUA_NETLIBK", value: 2048, body: "Bitmask for the network library.", origin: "lus" },
  { name: "LUA_WORKERLIBK", value: 4096, body: "Bitmask for the worker library.", origin: "lus" },
  { name: "LUA_VECLIBK", value: 8192, body: "Bitmask for the vector library.", origin: "lus" },
];

for (const c of LIB_CONSTS) {
  writeCapi("library", c.name, {
    name: c.name,
    header: "lualib.h",
    kind: "constant",
    since: "0.1.0",
    stability: "stable",
    origin: c.origin || "lua",
    type: "int",
    value: c.value,
  }, c.body);
}

// ─── lpledge.h ───

const PLEDGE_TYPES = [
  { name: "lus_PledgeRequest", sig: "typedef struct lus_PledgeRequest { const char *base; const char *sub; const char *value; const char *current; int status; int count; int has_base; } lus_PledgeRequest;", body: "Request structure passed to granter callbacks. Contains all information about the permission being granted or checked.\n\n`status` indicates the operation: `LUS_PLEDGE_GRANT` for new grants, `LUS_PLEDGE_UPDATE` for updates, `LUS_PLEDGE_CHECK` for access checks." },
  { name: "lus_PledgeGranter", sig: "typedef void (*lus_PledgeGranter)(lua_State *L, lus_PledgeRequest *p);", body: "Callback type for permission granters. Libraries register granters to handle their own permission validation logic.\n\nGranters should call `lus_setpledge` to confirm valid permissions. Unprocessed requests are automatically denied." },
];

for (const t of PLEDGE_TYPES) {
  writeCapi("pledge", t.name, {
    name: t.name,
    header: "lpledge.h",
    kind: "type",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    signature: t.sig,
  }, t.body);
}

const PLEDGE_CONSTS = [
  { name: "LUS_PLEDGE_GRANT", value: 0, body: "New permission request status code." },
  { name: "LUS_PLEDGE_UPDATE", value: 1, body: "Updating existing permission status code." },
  { name: "LUS_PLEDGE_CHECK", value: 2, body: "Read-only permission check status code." },
];

for (const c of PLEDGE_CONSTS) {
  writeCapi("pledge", c.name, {
    name: c.name,
    header: "lpledge.h",
    kind: "constant",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    type: "int",
    value: c.value,
  }, c.body);
}

const PLEDGE_FUNCS = [
  ["lus_initpledge", "void lus_initpledge (lua_State *L, lus_PledgeRequest *p, const char *base)", [{name:"L",type:"lua_State*"},{name:"p",type:"lus_PledgeRequest*"},{name:"base",type:"const char*"}], "Initializes a pledge request for C-side grants. This bypasses granters and is used for direct permission grants from C code."],
  ["lus_nextpledge", "int lus_nextpledge (lua_State *L, lus_PledgeRequest *p)", [{name:"L",type:"lua_State*"},{name:"p",type:"lus_PledgeRequest*"}], "Iterates through stored values for a permission. Sets `p->current` to the next stored value. Returns `1` if there are more values, `0` when done."],
  ["lus_setpledge", "void lus_setpledge (lua_State *L, lus_PledgeRequest *p, const char *sub, const char *value)", [{name:"L",type:"lua_State*"},{name:"p",type:"lus_PledgeRequest*"},{name:"sub",type:"const char*"},{name:"value",type:"const char*"}], "Confirms or sets a pledge value. Marks the request as processed, preventing automatic denial."],
  ["lus_rejectrequest", "void lus_rejectrequest (lua_State *L, lus_PledgeRequest *p)", [{name:"L",type:"lua_State*"},{name:"p",type:"lus_PledgeRequest*"}], "Permanently rejects a permission using the request struct. Future attempts to grant this permission will fail."],
  ["lus_pledgeerror", "void lus_pledgeerror (lua_State *L, lus_PledgeRequest *p, const char *msg)", [{name:"L",type:"lua_State*"},{name:"p",type:"lus_PledgeRequest*"},{name:"msg",type:"const char*"}], "Sets a denial error message for user-facing feedback."],
  ["lus_pledge", "int lus_pledge (lua_State *L, const char *name, const char *value)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"},{name:"value",type:"const char*"}], "Grants a permission to the Lua state. Triggers the granter callback for validation. Returns `1` on success, `0` if denied or sealed."],
  ["lus_haspledge", "int lus_haspledge (lua_State *L, const char *name, const char *value)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"},{name:"value",type:"const char*"}], "Checks if a permission has been granted. Returns `1` if access is allowed, `0` if denied."],
  ["lus_revokepledge", "int lus_revokepledge (lua_State *L, const char *name)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"}], "Revokes a previously granted permission. Returns `1` on success, `0` if sealed or not found."],
  ["lus_rejectpledge", "int lus_rejectpledge (lua_State *L, const char *name)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"}], "Permanently rejects a permission by name. Returns `1` on success, `0` if sealed."],
  ["lus_registerpledge", "void lus_registerpledge (lua_State *L, const char *name, lus_PledgeGranter granter)", [{name:"L",type:"lua_State*"},{name:"name",type:"const char*"},{name:"granter",type:"lus_PledgeGranter"}], "Registers a granter callback for a permission namespace."],
  ["lus_issealed", "int lus_issealed (lua_State *L)", [{name:"L",type:"lua_State*"}], "Returns `1` if the permission state is sealed, `0` otherwise."],
  ["lus_checkfsperm", "int lus_checkfsperm (lua_State *L, const char *perm, const char *path)", [{name:"L",type:"lua_State*"},{name:"perm",type:"const char*"},{name:"path",type:"const char*"}], "Convenience function for filesystem permission checks. Raises an error if denied."],
];

for (const [name, sig, params, body] of PLEDGE_FUNCS) {
  writeCapi("pledge", name, {
    name,
    header: "lpledge.h",
    kind: "function",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    signature: sig,
    params,
    returns: sig.startsWith("int") || sig.startsWith("void") ? undefined : [{type: sig.split(" ")[0]}],
  }, body);
}

// ─── lworkerlib.h ───

const WORKER_TYPES = [
  { name: "lus_WorkerSetup", sig: "typedef void (*lus_WorkerSetup)(lua_State *parent, lua_State *worker);", body: "Callback type for worker state initialization. Called when a new worker is created, allowing embedders to configure the worker's Lua state." },
];

for (const t of WORKER_TYPES) {
  writeCapi("worker", t.name, {
    name: t.name,
    header: "lworkerlib.h",
    kind: "type",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    signature: t.sig,
  }, t.body);
}

const WORKER_CONSTS = [
  { name: "LUS_WORKER_RUNNING", value: 0, body: "Worker status: running." },
  { name: "LUS_WORKER_BLOCKED", value: 1, body: "Worker status: blocked waiting for message." },
  { name: "LUS_WORKER_DEAD", value: 2, body: "Worker status: finished execution." },
  { name: "LUS_WORKER_ERROR", value: 3, body: "Worker status: terminated with error." },
];

for (const c of WORKER_CONSTS) {
  writeCapi("worker", c.name, {
    name: c.name,
    header: "lworkerlib.h",
    kind: "constant",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    type: "int",
    value: c.value,
  }, c.body);
}

const WORKER_CAPI_FUNCS = [
  ["lus_worker_pool_init", "void lus_worker_pool_init (lua_State *L)", [{name:"L",type:"lua_State*"}], "Initializes the global worker thread pool. Called automatically on first `worker.create()`."],
  ["lus_worker_pool_shutdown", "void lus_worker_pool_shutdown (void)", [], "Shuts down the worker thread pool. Waits for all threads to complete."],
  ["lus_onworker", "void lus_onworker (lua_State *L, lus_WorkerSetup fn)", [{name:"L",type:"lua_State*"},{name:"fn",type:"lus_WorkerSetup"}], "Registers a callback to be invoked when new worker states are created."],
  ["lus_worker_create", "WorkerState *lus_worker_create (lua_State *L, const char *path)", [{name:"L",type:"lua_State*"},{name:"path",type:"const char*"}], "Creates a new worker running the script at `path`."],
  ["lus_worker_send", "int lus_worker_send (lua_State *L, WorkerState *w, int idx)", [{name:"L",type:"lua_State*"},{name:"w",type:"WorkerState*"},{name:"idx",type:"int"}], "Sends the value at stack index `idx` to the worker's inbox."],
  ["lus_worker_receive", "int lus_worker_receive (lua_State *L, WorkerState *w)", [{name:"L",type:"lua_State*"},{name:"w",type:"WorkerState*"}], "Receives a message from the worker's outbox. Pushes the message onto the stack."],
  ["lus_worker_status", "int lus_worker_status (WorkerState *w)", [{name:"w",type:"WorkerState*"}], "Returns the status of a worker (`LUS_WORKER_RUNNING`, `LUS_WORKER_DEAD`, etc.)."],
];

for (const [name, sig, params, body] of WORKER_CAPI_FUNCS) {
  writeCapi("worker", name, {
    name,
    header: "lworkerlib.h",
    kind: "function",
    since: "0.1.0",
    stability: "stable",
    origin: "lus",
    signature: sig,
    params: params.length ? params : undefined,
  }, body);
}

// ─── DONE ───

// Count generated files
let count = 0;
function countFiles(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) countFiles(path.join(dir, entry.name));
    else if (entry.name.endsWith(".md") && entry.name !== "README.md") count++;
  }
}
countFiles(SPEC);
console.log(`Generated ${count} spec files.`);
