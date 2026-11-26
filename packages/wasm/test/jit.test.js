// Tests for the WebAssembly JIT (spec/design/wasmjit.md). Build the
// module first with `mise run wasm`.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { describe, test } from "node:test";
import { Lus, defaultWasmPath, loadLus } from "../src/node.js";

if (!existsSync(defaultWasmPath)) {
  throw new Error(`${defaultWasmPath} is missing. Run \`mise run wasm\` first.`);
}

const bytes = readFileSync(defaultWasmPath);
const module = new WebAssembly.Module(bytes);

/** A host whose states use the JIT setting `mode`. */
function host(mode, options = {}) {
  return new Lus(module, { env: { LUS_JIT: mode }, ...options });
}

/**
 * Runs `source` and returns its standard output, failing on errors. A host
 * grant takes `debug` away unless it names it, as `lus -P` does, so the
 * grants name `debug` for the programs that set hooks.
 */
function output(lus, source) {
  const r = lus.run(source, { pledges: ["load", "debug"] });
  assert.equal(r.error, null, r.traceback ?? undefined);
  return r.stdout;
}

// Every part of this program runs with the JIT off, on, and eager, and
// must print the same thing. Each function runs often enough to compile
// under the default threshold, and is then called with operands that its
// fast paths do not take, so that the step routines finish them.
const DEOPT = String.raw`
local function arith(a, b) return a + b, a - b, a * b, a / b, a // b, a % b, -a end
local function cmp(a, b) return a < b, a <= b, a == b, a > b end
local function field(t) return t.x end
local function store(t, v) t.x = v return t.x end
local function index(t, i) return t[i] end
local function put(t, i, v) t[i] = v return t[i] end
for _ = 1, 200 do arith(7, 3) cmp(1, 2) field({ x = 1 }) store({ x = 1 }, 2) index({ 1, 2 }, 2) put({ 1, 2 }, 1, 5) end
-- Floats, mixed numbers, strings, and metamethods.
print(arith(7.5, 2), arith(7, 2.5), arith(-7, 2))
print(arith("10", 4))
local V = setmetatable({}, { __add = function() return "add" end, __sub = function() return "sub" end,
  __mul = function() return "mul" end, __div = function() return "div" end, __idiv = function() return "idiv" end,
  __mod = function() return "mod" end, __unm = function() return "unm" end })
print(arith(V, 1))
print(cmp(1.5, 2), cmp(2, 1.5), cmp("a", "b"), cmp(0/0, 0/0))
print(catch arith(1, 0))
print(catch arith({}, 1))
print(catch cmp({}, 1))
print(math.maxinteger + 1 == math.mininteger, arith(math.mininteger, -1))
-- Table accesses that miss the inline caches and the array part.
local proxy = setmetatable({}, { __index = function(_, k) return "idx:" .. k end })
print(field(proxy), field(setmetatable({}, { __index = { x = "inherited" } })))
print(catch field(nil))
local seen = {}
local guarded = setmetatable({}, { __newindex = function(_, k, v) seen[k] = v end })
print(store(guarded, 9), seen.x)
print(index({ 1, 2 }, 5), index({ 1, 2 }, 0), index({ 1.5, 2.5 }, 2), index("abc", "len") ~= nil)
print(index(setmetatable({}, { __index = function(_, i) return i * 2 end }), 21))
local t = { 1, 2, 3 }
print(put(t, 4, "grow"), put(t, 1, 1.5), put(t, "k", "v"), #t)
print(catch put("str", 1, 2))
`;

// Calls, returns, tail calls, recursion deeper than compiled code nests,
// errors caught in compiled frames, coroutines, and finalizers.
const CALLS = String.raw`
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
local function tail(n, acc) if n == 0 then return acc end return tail(n - 1, acc + 1) end
local function many() return 1, 2, 3 end
local function count(...) return select("#", ...) end
local function boom(n) if n == 0 then error("deep") end return boom(n - 1) end
for _ = 1, 100 do fib(5) depth(3) tail(3, 0) count(many()) end
print(fib(20), depth(5000), tail(100000, 0), count(many()), (many()))
print(catch boom(500))
local function guard(n)
    local ok, err = catch boom(n)
    return ok, err
end
for _ = 1, 100 do guard(1) end
print(guard(3))
local gen = coroutine.wrap(function()
    for i = 1, 300 do coroutine.yield(fib(i % 10)) end
end)
local sum = 0
for _ = 1, 300 do sum = sum + gen() end
print(sum)
local closed = 0
for i = 1, 2000 do
    local x <close> = setmetatable({}, { __close = function() closed = closed + 1 end })
    setmetatable({}, { __gc = function() closed = closed + 0 end })
end
collectgarbage()
print(closed)
local calls = 0
debug.sethook(function() calls = calls + 1 end, "c")
fib(5)
debug.sethook()
print(calls > 0)
`;

describe("the JIT", () => {
  test("lus.wasm needs nothing but WASI from its host", () => {
    // A plain WASI runner instantiates the module, and it stays
    // interpreted there.
    for (const im of WebAssembly.Module.imports(module)) assert.equal(im.module, "wasi_snapshot_preview1");
    const names = WebAssembly.Module.exports(module).map((e) => e.name);
    assert.ok(names.includes("__indirect_function_table"));
    assert.ok(names.includes("lus_wasm_jit_host"));
  });

  test("compiles hot functions", () => {
    const lus = host("on");
    assert.ok(lus.jit);
    const out = output(
      lus,
      `local function sum(n) local s = 0 for i = 1, n do s = s + i end return s end
       for _ = 1, 100 do sum(10) end
       print(debug.jit(), debug.jit(sum), sum(1000000))`,
    );
    assert.equal(out, "on\ttrue\t500000500000\n");
    assert.ok(lus.jit.stats.modules >= 1);
    assert.ok(lus.jit.runtimeStats().compiled >= 1);
  });

  for (const [name, source] of [
    ["falls back to the interpreter where fast paths do not apply", DEOPT],
    ["runs calls, errors, coroutines, and hooks like the interpreter", CALLS],
  ]) {
    test(name, () => {
      const expected = output(host("off"), source);
      for (const mode of ["on", "eager"]) {
        const lus = host(mode);
        assert.equal(output(lus, source), expected, `LUS_JIT=${mode}`);
        assert.ok(lus.jit.stats.modules > 0);
        assert.equal(lus.jit.stats.failed, 0);
      }
    });
  }

  test("stays interpreted without a JIT host", async () => {
    const lus = await loadLus(defaultWasmPath, { jit: false, env: { LUS_JIT: "eager" } });
    assert.equal(lus.jit, null);
    const out = output(lus, `local function f() return 1 end f() print(debug.jit(), debug.jit(f))`);
    assert.equal(out, "off\tfalse\tfalse\n");
    assert.equal(output(lus, CALLS), output(host("off"), CALLS));
  });

  test("keeps interpreting a function the host fails to compile", () => {
    const lus = host("eager");
    const errors = [];
    lus.jit.onError = (e) => errors.push(e);
    const compile = lus.jit.compile.bind(lus.jit);
    // The host refuses every other module.
    let n = 0;
    lus.jit.compile = (ptr, len, reuse) => (n++ % 2 ? 0 : compile(ptr, len, reuse));
    assert.equal(output(lus, DEOPT), output(host("off"), DEOPT));
    assert.ok(lus.jit.runtimeStats().failed > 0);
    // A host that throws while compiling declines as well.
    lus.jit.compile = (ptr, len, reuse) => {
      try {
        throw new Error("no compiler");
      } catch (error) {
        lus.jit.onError?.(error);
        return 0;
      }
    };
    assert.equal(output(lus, CALLS), output(host("off"), CALLS));
    assert.ok(errors.length > 0);
  });

  test("installs modules compiled in the background on a later call", async () => {
    // Every module goes to the background, as a large one does.
    const lus = host("on", { jit: { syncLimit: 0 } });
    const l = lus.create({ pledges: ["load"] });
    lus.execute(l, "function hot(n) local s = 0 for i = 1, n do s = s + i end return s end");
    let compiled = false;
    for (let i = 0; i < 20 && !compiled; i++) {
      lus.execute(l, "for _ = 1, 2000 do hot(10) end");
      compiled = lus.execute(l, "debug.jit(hot)").startsWith("true");
      await delay(5);
    }
    assert.ok(compiled, "the background module was never installed");
    assert.equal(lus.execute(l, "hot(100)"), "5050\n");
    assert.ok(lus.jit.stats.deferred > 0);
    lus.destroy(l);
  });

  test("reuses the table slots of collected functions", () => {
    const lus = host("eager");
    const program = `local function f(x) return x + 1 end print(f(1))`;
    output(lus, program);
    const size = lus.exports.__indirect_function_table.length;
    for (let i = 0; i < 20; i++) output(lus, program);
    assert.equal(lus.exports.__indirect_function_table.length, size);
  });
});
