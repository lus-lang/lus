// Generates random Lus programs for differential testing.
//
// A program is built from a typed model of the language. Every expression
// the generator emits has a known type, so most programs run to their end
// instead of stopping at the first type error. A program prints a trace of
// the values it computes through `P`, which renders every value without
// addresses and without depending on the order of `pairs`, so every
// configuration of the runtime must print the same trace.
//
// The body of a program is a set of units, each a function called many
// times from a loop with arguments whose types change halfway through the
// loop. That crosses the JIT thresholds in the middle of a run and makes
// optimized code leave through its guards. Each call runs under `catch`,
// so an error ends one call and the trace records its message.
//
// Usage: node gen.mjs SEED [--size N] prints one program.

const INT_EDGES = [
    "0", "1", "-1", "2", "3", "7", "10", "-7", "255", "256", "65535", "2147483647", "-2147483648",
    "4294967296", "math.maxinteger", "math.mininteger", "(math.maxinteger - 1)", "(math.mininteger + 1)",
    "0x7f", "0xff", "1000000007",
];
const FLOAT_EDGES = [
    "0.5", "-0.5", "1.5", "2.0", "-0.0", "0.1", "1e15", "1e300", "-1e300", "3.25", "1e-300",
    "math.huge", "-math.huge", "(2^53)", "(2^63)", "(-(2^63))", "math.pi", "0.0", "1e16",
];
const BIG_EDGES = [
    "0n", "1n", "-1n", "2n", "10n", "12345678901234567890n", "-98765432109876543210n",
    "(2n ^ 64)", "(2n ^ 63)", "(-(2n ^ 63))", "9223372036854775807n", "9223372036854775808n", "7n",
];
const DEC_EDGES = [
    "0d", "1d", "-1d", "0.1d", "0.2d", "1.50d", "2.25d", "-3.125d", "100d", "0.001d",
    "12345678901234567890.5d", "1e10d", "7d", "0.3d",
];
const STR_EDGES = [
    `""`, `"a"`, `"abc"`, `"hello"`, `"héllo"`, `"日本語"`, `"a,b,c"`, `"  x  "`, `"10"`, `"0x10"`,
    `"3.5"`, `"1e2"`, `"-7"`, `"\\0"`, `"tab\\tnl\\n"`, `"\\u{1F600}x"`, `"\\u{D800}"`, `"%d"`, `"$"`,
    `"AbC"`, `"zz"`, `"a.b"`, `"nan"`,
];
const ENUM_MEMBERS = ["Red", "Green", "Blue", "Cyan", "Magenta"];

class Rng {
    constructor(seed) {
        this.s = (BigInt(seed) * 0x9E3779B97F4A7C15n + 1n) & 0xFFFFFFFFFFFFFFFFn;
        if (this.s === 0n) this.s = 1n;
    }
    next() {
        // xorshift64*
        let x = this.s;
        x ^= x >> 12n;
        x ^= (x << 25n) & 0xFFFFFFFFFFFFFFFFn;
        x ^= x >> 27n;
        this.s = x;
        return Number(((x * 0x2545F4914F6CDD1Dn) & 0xFFFFFFFFFFFFFFFFn) >> 11n) / 2 ** 53;
    }
    int(n) { return Math.floor(this.next() * n); }
    range(a, b) { return a + this.int(b - a + 1); }
    chance(p) { return this.next() < p; }
    pick(a) { return a[this.int(a.length)]; }
    weighted(pairs) {
        let total = 0;
        for (const [w] of pairs) total += w;
        let r = this.next() * total;
        for (const [w, v] of pairs) {
            if ((r -= w) < 0) return v;
        }
        return pairs[pairs.length - 1][1];
    }
}

// The prelude defines the trace printer and the helpers that the units
// share: a metatable for objects, a factory of to-be-closed values, and
// an enum. It is the same for every program.
export const PRELUDE = String.raw`local __print, __type, __tostring, __mtype = print, type, tostring, math.type
local __concat, __sort, __select, __next = table.concat, table.sort, select, next
local S
S = function(v, d)
    local t = __type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v then return "nan" end
        return __mtype(v) .. ":" .. __tostring(v)
    end
    if t == "table" then
        d = d or 0
        if d > 2 then return "{...}" end
        local parts = {}
        for k, x in __next, v do parts[#parts + 1] = S(k, d + 1) .. "=" .. S(x, d + 1) end
        __sort(parts)
        return "{" .. __concat(parts, ",") .. "}"
    end
    if t == "enum" then return "enum:" .. __tostring(tonumber(v)) end
    if t == "boolean" or t == "nil" then return __tostring(v) end
    return t
end
local function P(...)
    local n = __select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = S((__select(i, ...))) end
    __print(__concat(parts, " "))
end
local MT = {}
local function O(x) return setmetatable({ x = x }, MT) end
MT.__add = function(a, b)
    local ax = __type(a) == "table" and a.x or a
    local bx = __type(b) == "table" and b.x or b
    return O(ax + bx)
end
MT.__sub = function(a, b)
    local ax = __type(a) == "table" and a.x or a
    local bx = __type(b) == "table" and b.x or b
    return O(ax - bx)
end
MT.__unm = function(a) return O(-a.x) end
MT.__len = function(a) return a.x % 97 end
MT.__eq = function(a, b) return a.x == b.x end
MT.__lt = function(a, b) return a.x < b.x end
MT.__le = function(a, b) return a.x <= b.x end
MT.__call = function(self, y) return self.x * 2 + (y or 0) end
MT.__concat = function(a, b)
    local as = __type(a) == "table" and ("O" .. __tostring(a.x)) or __tostring(a)
    local bs = __type(b) == "table" and ("O" .. __tostring(b.x)) or __tostring(b)
    return as .. bs
end
MT.__index = function(self, k)
    if k == "dbl" then return self.x * 2 end
    return #__tostring(k)
end
local function C(tag)
    return setmetatable({}, { __close = function(_, e) P("close", tag, e) end })
end
local E = enum Red, Green, Blue, Cyan, Magenta end
local __detached = 0
local __rows = function(n, k)
    local t = {}
    for i = 1, n do t[i] = { x = (i * k) % 11, y = "r" .. i, z = i % 3 } end
    return t
end
`;

// Types of the model. Parameters of units start as integers and become
// floats or numeric strings halfway through the driving loop, so integer
// typed code also runs on other values.
const TYPES = ["int", "int", "int", "float", "big", "dec", "str", "str", "bool", "arr", "obj", "fn", "enum", "rec"];

class Scope {
    constructor(parent) {
        this.parent = parent;
        this.vars = [];
    }
    all(type) {
        const out = [];
        for (let s = this; s; s = s.parent) for (const v of s.vars) if (v.type === type) out.push(v);
        return out;
    }
}

class Gen {
    constructor(seed, size) {
        this.r = new Rng(seed);
        this.size = size;
        this.names = 0;
        this.lines = [];
        this.indent = 0;
    }
    fresh(prefix) { return `${prefix}${++this.names}`; }
    emit(s) { this.lines.push("    ".repeat(this.indent) + s); }

    // ----- expressions -----

    varOf(scope, type) {
        const vs = scope.all(type);
        return vs.length ? this.r.pick(vs).name : null;
    }

    expr(scope, type, depth = 0) {
        const r = this.r;
        const leaf = depth > 3 || r.chance(0.3 + depth * 0.15);
        const v = this.varOf(scope, type);
        if (leaf) {
            if (v && r.chance(0.65)) return v;
            return this.literal(type);
        }
        const f = this[`x_${type}`];
        return f.call(this, scope, depth + 1, v);
    }

    literal(type) {
        const r = this.r;
        switch (type) {
            case "int": return r.chance(0.5) ? String(r.range(-20, 100)) : r.pick(INT_EDGES);
            case "float": return r.chance(0.4) ? `${r.range(-50, 50)}.${r.range(0, 99)}` : r.pick(FLOAT_EDGES);
            case "big": return r.chance(0.4) ? `${r.range(-1000, 100000)}n` : r.pick(BIG_EDGES);
            case "dec": return r.chance(0.4) ? `${r.range(-100, 1000)}.${r.range(0, 999)}d` : r.pick(DEC_EDGES);
            case "str": return r.pick(STR_EDGES);
            case "bool": return r.pick(["true", "false"]);
            case "arr": {
                const n = r.range(0, 6);
                const items = [];
                for (let i = 0; i < n; i++) items.push(this.literal("int"));
                return `{ ${items.join(", ")} }`;
            }
            case "obj": return `O(${this.literal("int")})`;
            case "fn": return `function(q) return q + ${this.literal("int")} end`;
            case "enum": return `E.${r.pick(ENUM_MEMBERS)}`;
            case "rec": return `__rows(${r.range(0, 8)}, ${r.range(1, 7)})`;
        }
        throw new Error(type);
    }

    x_int(scope, d, v) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [6, () => `(${e("int")} ${r.pick(["+", "-", "*", "+", "-"])} ${e("int")})`],
            [2, () => `(${e("int")} ${r.pick(["//", "%"])} ${e("int")})`],
            [2, () => `(${e("int")} ${r.pick(["&", "|", "~", "<<", ">>"])} ${e("int")})`],
            [1, () => `(~ ${e("int")})`],
            [1, () => `(- ${e("int")})`],
            [2, () => `#${e("str")}`],
            [2, () => `#${e("arr")}`],
            [1, () => `(math.tointeger(${e("float")}) or ${e("int")})`],
            [2, () => `(${e("fn")})(${e("int")})`],
            [2, () => { const a = e("arr"); return `((${a})[${e("int")} % 7 + 1] or ${this.literal("int")})`; }],
            [1, () => `(${e("bool")} and ${e("int")} or ${e("int")})`],
            [1, () => `math.${r.pick(["max", "min"])}(${e("int")}, ${e("int")})`],
            [1, () => `math.abs(${e("int")})`],
            [1, () => `(string.find(${e("str")}, ${e("str")}, 1, true) or -1)`],
            [1, () => `tonumber(${e("enum")})`],
            [1, () => `(${e("obj")}).x`],
            [1, () => `#${e("obj")}`],
            [1, () => `(${e("obj")})(${e("int")})`],
            [1, () => `(${e("obj")}).${r.pick(["dbl", "abc", "k"])}`],
            [1, () => `(math.tointeger(${e("big")} % 1000n) or 0)`],
            [1, () => `(math.tointeger(${e("dec")} // 1d) or 0)`],
            [1, () => `do local t = ${e("int")} if t > ${e("int")} then provide t end provide -t end`],
            [1, () => `select("#", ${this.args(scope, d)})`],
            [1, () => `(${e("int")} * 31 + ${e("int")}) % 1000003`],
            [1, () => `(utf8.len(${e("str")}) or 0)`],
            [1, () => `#(${e("rec")})`],
            [1, () => `math.floor(${e("float")} % 1000)`],
            [1, () => `string.len(string.rep(${e("str")}, ${r.range(0, 4)}))`],
        ])();
    }

    x_float(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [4, () => `(${e("float")} ${r.pick(["+", "-", "*", "/"])} ${e("float")})`],
            [3, () => `(${e("int")} ${r.pick(["/", "+", "*", "-"])} ${e("float")})`],
            [2, () => `(${e("int")} / ${e("int")})`],
            [1, () => `(${e("float")} ${r.pick(["//", "%", "^"])} ${e("float")})`],
            [1, () => `math.${r.pick(["sqrt", "sin", "cos", "exp", "log"])}(${e("float")})`],
            [1, () => `(${e("int")} + 0.0)`],
            [1, () => `(tonumber(${e("big")}) + 0.5)`],
            [1, () => `(tonumber(${e("str")}) or 0.25)`],
            [1, () => `(- ${e("float")})`],
            [1, () => `math.fmod(${e("float")}, ${e("float")})`],
        ])();
    }

    x_big(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [4, () => `(${e("big")} ${r.pick(["+", "-", "*"])} ${e("big")})`],
            [2, () => `(${e("big")} ${r.pick(["+", "-", "*", "//", "%"])} ${e("int")})`],
            [1, () => `(${e("big")} ${r.pick(["//", "%"])} ${e("big")})`],
            [1, () => `(${e("big")} ${r.pick(["&", "|", "~", "<<", ">>"])} ${r.range(0, 70)})`],
            [1, () => `(${e("big")} ^ ${r.range(0, 40)})`],
            [1, () => `bigint(${e("int")})`],
            [1, () => `(- ${e("big")})`],
        ])();
    }

    x_dec(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [4, () => `(${e("dec")} ${r.pick(["+", "-", "*"])} ${e("dec")})`],
            [2, () => `(${e("dec")} ${r.pick(["+", "-", "*", "/"])} ${e("int")})`],
            [1, () => `(${e("dec")} ${r.pick(["/", "//", "%"])} ${e("dec")})`],
            [1, () => `(${e("dec")} + ${e("big")})`],
            [1, () => `decimal(${e("int")})`],
            [1, () => `(- ${e("dec")})`],
            [1, () => `(${e("dec")} ^ ${r.range(0, 6)})`],
        ])();
    }

    x_str(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [3, () => `(${e("str")} .. ${e("str")})`],
            [2, () => `(${e("str")} .. ${e(r.pick(["int", "float", "big", "dec"]))})`],
            [2, () => `tostring(${e(r.pick(["int", "float", "big", "dec", "bool"]))})`],
            [2, () => `\`<$(${e("int")})|$(${e("str")})>\``],
            [2, () => `string.sub(${e("str")}, ${e("int")}, ${e("int")})`],
            [1, () => `(${e("str")})[${r.range(-3, 4)}, ${r.range(-2, 6)}]`],
            [1, () => `string.${r.pick(["upper", "lower", "reverse"])}(${e("str")})`],
            [1, () => `string.rep(${e("str")}, ${r.range(0, 3)}, ${e("str")})`],
            [1, () => `string.format("%d|%5.2f|%s|%x", ${e("int")}, ${e("float")}, ${e("str")}, ${e("int")})`],
            [1, () => `string.format("%q|%g|%10.3s", ${e("str")}, ${e("float")}, ${e("str")})`],
            [1, () => `table.concat(${e("arr")}, ${e("str")})`],
            [1, () => `(string.gsub(${e("str")}, ${r.pick([`"a"`, `"%a"`, `"[%d.]+"`, `"(%w)(%w)"`, `"."`, `"%s+"`])}, ${r.pick([`"<%0>"`, `"%2%1"`, `""`, `string.upper`])}))`],
            [1, () => `(string.match(${e("str")}, ${r.pick([`"%a+"`, `"(%d+)"`, `"^(.-)$"`, `"[^,]+"`])}) or "")`],
            [1, () => `(${e("obj")} .. ${e("str")})`],
            [1, () => `(${e("bool")} and ${e("str")} or ${e("str")})`],
            [1, () => `(utf8.char(${r.pick(["65", "233", "0x65E5", "0x1F600", "0xD800"])}) .. ${e("str")})`],
        ])();
    }

    x_bool(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        const cmp = () => r.pick(["<", "<=", ">", ">=", "==", "~="]);
        return r.weighted([
            [4, () => `(${e("int")} ${cmp()} ${e("int")})`],
            [2, () => `(${e("int")} ${cmp()} ${e("float")})`],
            [1, () => `(${e("float")} ${cmp()} ${e("float")})`],
            [1, () => `(${e("big")} ${cmp()} ${e("int")})`],
            [1, () => `(${e("dec")} ${cmp()} ${e(r.pick(["int", "big", "dec", "float"]))})`],
            [1, () => `(${e("str")} ${cmp()} ${e("str")})`],
            [2, () => `(not ${e("bool")})`],
            [2, () => `(${e("bool")} ${r.pick(["and", "or"])} ${e("bool")})`],
            [1, () => `(${e("enum")} ${cmp()} ${e("enum")})`],
            [1, () => `(${e("obj")} ${r.pick(["<", "<=", "==", "~="])} ${e("obj")})`],
            [1, () => `(${e("arr")})[1] == nil`],
            [1, () => `rawequal(${e("str")}, ${e("str")})`],
            [1, () => `(math.type(${e(r.pick(["int", "float"]))}) == "integer")`],
        ])();
    }

    x_arr(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [3, () => this.literal("arr")],
            [2, () => `{ ${e("int")}, ${e("int")}, ${e("int")} }`],
            [1, () => `table.clone(${e("arr")})`],
            [1, () => `(${e("arr")})[${r.range(1, 3)}, ${r.range(0, 6)}]`],
            [1, () => `{ table.unpack(${e("arr")}) }`],
        ])();
    }

    x_obj(scope, d) {
        const r = this.r;
        const e = (t) => this.expr(scope, t, d);
        return r.weighted([
            [2, () => `O(${e("int")})`],
            [2, () => `(${e("obj")} + ${e(r.pick(["obj", "int"]))})`],
            [1, () => `(${e("obj")} - ${e("int")})`],
            [1, () => `(- ${e("obj")})`],
        ])();
    }

    x_fn(scope, d) {
        const r = this.r;
        const inner = new Scope(scope);
        const q = this.fresh("q");
        inner.vars.push({ name: q, type: "int" });
        return r.weighted([
            [3, () => `function(${q}) return ${this.expr(inner, "int", d)} end`],
            [1, () => `function(${q}, ...) local t = { ... } return ${q} + #t end`],
        ])();
    }

    x_enum(scope, d) {
        const r = this.r;
        return r.weighted([
            [2, () => `E.${r.pick(ENUM_MEMBERS)}`],
            [1, () => `E[${r.range(1, 5)}]`],
            [1, () => `E.${r.pick(ENUM_MEMBERS)}.${r.pick(ENUM_MEMBERS)}`],
        ])();
    }

    x_rec(scope, d) {
        return `__rows(${this.r.range(0, 9)}, ${this.expr(scope, "int", d)} % 13 + 1)`;
    }

    args(scope, d) {
        const n = this.r.range(0, 4);
        const out = [];
        for (let i = 0; i < n; i++) out.push(this.r.chance(0.2) ? "nil" : this.expr(scope, this.r.pick(TYPES), d + 1));
        return out.length ? out.join(", ") : "nil";
    }

    // ----- statements -----

    block(scope, budget, ctx) {
        const inner = new Scope(scope);
        let n = this.r.range(1, Math.max(1, budget));
        while (n-- > 0) this.stmt(inner, ctx);
        return inner;
    }

    nested(header, scope, ctx, footer = "end", setup) {
        this.emit(header);
        this.indent++;
        const inner = new Scope(scope);
        if (setup) setup(inner);
        let n = this.r.range(1, 4);
        while (n-- > 0) this.stmt(inner, { ...ctx, depth: ctx.depth + 1 });
        this.indent--;
        this.emit(footer);
    }

    declare(scope, type, name) {
        name = name || this.fresh(type[0]);
        this.emit(`local ${name} = ${this.expr(scope, type)}`);
        scope.vars.push({ name, type });
        return name;
    }

    stmt(scope, ctx) {
        const r = this.r;
        const deep = ctx.depth >= 3;
        const kinds = [
            [6, "local"], [4, "assign"], [5, "trace"], [1, "arrpush"],
        ];
        if (!deep) {
            kinds.push([3, "if"], [3, "for"], [1, "forin"], [1, "while"], [1, "repeat"], [1, "func"],
                [1, "closure"], [2, "catch"], [1, "close"], [1, "coro"], [1, "query"], [1, "ifassign"],
                [1, "vararg"], [1, "do"], [1, "multi"], [1, "group"], [1, "tostr"], [1, "goto"],
                [3, "kernel"], [2, "shape"], [1, "poly"], [1, "edgecmp"], [1, "edgefor"], [1, "coerce"],
                [1, "method"], [1, "keys"], [1, "deep"], [1, "concatn"], [1, "chain"], [1, "detach"],
                [2, "upvals"], [2, "globals"], [1, "tail"], [2, "multiret"], [1, "metaflip"], [2, "hotcall"]);
            if (ctx.coro) kinds.push([2, "yield"]);
        }
        if (ctx.loop) kinds.push([1, "continue"], [1, "break"]);
        if (ctx.func) kinds.push([1, "return"]);
        if (ctx.depth > 0) kinds.push([1, "error"]);
        const kind = r.weighted(kinds.map(([w, k]) => [w, k]));
        this[`s_${kind}`](scope, ctx);
    }

    s_local(scope) {
        this.declare(scope, this.r.pick(TYPES));
    }

    s_assign(scope) {
        const t = this.r.pick(TYPES);
        const v = scope.all(t).filter((x) => !x.fixed);
        if (!v.length) return this.s_local(scope);
        this.emit(`${this.r.pick(v).name} = ${this.expr(scope, t)}`);
    }

    s_trace(scope) {
        const n = this.r.range(1, 3);
        const items = [];
        for (let i = 0; i < n; i++) items.push(this.expr(scope, this.r.pick(TYPES)));
        this.emit(`P(${JSON.stringify(this.fresh("t"))}, ${items.join(", ")})`);
    }

    s_tostr(scope) {
        const t = this.r.pick(["int", "float", "big", "dec"]);
        this.emit(`P(tostring(${this.expr(scope, t)}), math.type(${this.expr(scope, t)}))`);
    }

    s_arrpush(scope) {
        const a = this.varOf(scope, "arr");
        if (!a) return this.declare(scope, "arr");
        const r = this.r;
        r.weighted([
            [3, () => this.emit(`${a}[#${a} + 1] = ${this.expr(scope, "int")}`)],
            [1, () => this.emit(`table.insert(${a}, ${this.expr(scope, "int")})`)],
            [1, () => this.emit(`if #${a} > 0 then P("rm", table.remove(${a}, 1)) end`)],
            [1, () => this.emit(`table.sort(${a}, function(x, y) return x > y end)`)],
            [1, () => this.emit(`${a}[${r.range(1, 4)}] = ${this.expr(scope, "int")}`)],
        ])();
    }


    // A loop over an array whose elements change kind partway: integers,
    // then floats, then strings or nil. Code compiled for one kind of
    // array meets another.
    s_kernel(scope) {
        const r = this.r;
        const a = this.fresh("ka"), acc = this.fresh("acc"), i = this.fresh("ki");
        const n = r.range(1, 70);
        const flip = r.range(1, n + 1);
        const later = r.pick(["i + 0.5", "i * 1.0", "-i", "i // 2", "tostring(i)", "math.maxinteger - i", "i * 2^40", "(i % 2 == 0) and i or i + 0.25", "2^53 + i", "nil"]);
        this.emit(`local ${a} = {}`);
        this.emit(`for i = 1, ${n} do ${a}[i] = i < ${flip} and (i * ${r.range(1, 9)} - ${r.range(0, 9)}) or ${later} end`);
        this.emit(`local ${acc} = ${r.pick(["0", "0.0", "1", "math.maxinteger"])}`);
        const op = r.pick(["+", "-", "*", "+"]);
        this.emit(`for ${i} = 1, #${a} do`);
        this.indent++;
        this.emit(`local v = ${a}[${i}]`);
        r.weighted([
            [3, () => this.emit(`if v then ${acc} = ${acc} ${op} v end`)],
            [1, () => this.emit(`${acc} = ${acc} ${op} (v or 0) * ${r.pick(["2", "0.5", "-1"])}`)],
            [1, () => this.emit(`if v and v ${r.pick(["<", ">", "==", "<="])} ${this.literal(r.pick(["int", "float"]))} then ${acc} = ${acc} + 1 end`)],
            [1, () => this.emit(`${a}[${i}] = v and v ${op} ${this.literal("int")} or false`)],
        ])();
        this.indent--;
        this.emit("end");
        this.emit(`P("kernel", ${acc}, #${a}, ${a}[1], ${a}[#${a}])`);
        if (r.chance(0.5)) scope.vars.push({ name: acc, type: "int" });
    }

    // Tables built with the same fields in different orders, read through
    // one site, so inline caches meet several shapes.
    s_shape(scope) {
        const r = this.r;
        const t = this.fresh("sh"), f = this.fresh("rd");
        const fields = ["a", "b", "c", "d"];
        this.emit(`local function ${f}(o) return (o.a or 0) + (o.b or 0) * 2 + (o.c or 0) * 3 end`);
        this.emit(`local ${t} = {}`);
        const n = r.range(2, 40);
        this.emit(`for i = 1, ${n} do`);
        this.indent++;
        this.emit(`local o = {}`);
        this.emit(`if i % ${r.range(2, 5)} == 0 then o.c = i o.a = 1 elseif i % 3 == 1 then o.a = i o.b = 2 o.c = 3 else o.b = i o.d = "x" end`);
        if (r.chance(0.3)) this.emit(`if i == ${r.range(1, n)} then setmetatable(o, { __index = function(_, k) return #k end }) end`);
        if (r.chance(0.3)) this.emit(`if i % 7 == 0 then o.a = nil end`);
        if (r.chance(0.3)) this.emit(`if i % 5 == 0 then o.${r.pick(fields)} = ${r.pick(["1.5", "\"s\"", "nil", "true"])} end`);
        this.emit(`${t}[#${t} + 1] = ${f}(o)`);
        this.indent--;
        this.emit("end");
        this.emit(`P("shape", table.concat(${t}, ","))`);
    }

    // A value whose subtype changes between iterations.
    s_poly(scope) {
        const r = this.r;
        const x = this.fresh("px"), acc = this.fresh("pa");
        this.emit(`local ${acc} = 0`);
        this.emit(`for i = 1, ${r.range(5, 80)} do`);
        this.indent++;
        this.emit(`local ${x} = (i % ${r.range(2, 6)} == 0) and ${r.pick(["i + 0.5", "i * 1.0", "\"7\"", "i * 1n", "math.maxinteger"])} or i`);
        this.emit(`${acc} = ${acc} ${r.pick(["+", "-", "*", "//", "%"])} (${x} ${r.pick(["+", "*", "-", "//"])} ${r.pick(["1", "2.0", "3", "i"])})`);
        if (r.chance(0.5)) this.emit(`if ${x} ${r.pick(["<", "==", ">="])} ${r.pick(["10", "10.5", "i"])} then ${acc} = ${acc} + 1 end`);
        this.indent--;
        this.emit("end");
        this.emit(`P("poly", ${acc})`);
    }

    // Comparisons and conversions at the edges of the integer and float
    // ranges, where a fast path that converts one side is wrong.
    s_edgecmp(scope) {
        const r = this.r;
        const ints = ["math.maxinteger", "math.mininteger", "9007199254740993", "-9007199254740993", "(1 << 53)", "((1 << 53) + 1)", "0", "-1", "(math.maxinteger - 511)"];
        const floats = ["2^63", "-2^63", "2^53", "(2^53 + 1)", "9007199254740992.0", "math.huge", "-math.huge", "(0/0)", "-0.0", "0.5", "9.2233720368547758e18", "1e308"];
        const a = r.pick(ints), b = r.pick(floats);
        const op = r.pick(["<", "<=", "==", "~=", ">", ">="]);
        const f = this.fresh("ec");
        this.emit(`local function ${f}(x, y) return x ${op} y, y ${op} x, x == y, math.tointeger(y), x + 0.0 == y end`);
        this.emit(`for _ = 1, ${r.range(1, 20)} do P("edge", ${f}(${a}, ${b})) end`);
        if (r.chance(0.5)) this.emit(`P("edgeconv", math.tointeger(${b}), ${b} // 1, catch ${a} // ${r.pick(["0", "-1", "1"])}, ${a} % ${r.pick(["-1", "3", "-3", "math.mininteger"])}, (${a}) * 2, ${a} >> 1, ${a} << 63)`);
        if (r.chance(0.3)) this.emit(`P("fmt", string.format("%.17g %d %5.1f", ${b}, ${a}, ${b}), tostring(${b}), ${b} == ${b}, catch math.floor(${b}))`);
    }

    // Numeric loops at the edges of the integer range and with float
    // steps, which must stop exactly where the interpreter stops.
    s_edgefor(scope) {
        const r = this.r;
        const i = this.fresh("e");
        const forms = [
            "math.maxinteger - 3, math.maxinteger", "math.mininteger, math.mininteger + 3", "math.mininteger + 2, math.mininteger, -1",
            "1, 3, 0.75", "3, 1, -0.5", "0.1, 1, 0.3", "1, 0", "1, 1", "math.maxinteger - 1, math.maxinteger, 2",
            "-3, 3, math.maxinteger", "1, 2.5", "1.0, 3", "2^53 - 2, 2^53 + 2", "1, 3, 1.0",
        ];
        this.emit(`P("ef", catch (function() local n, s = 0, 0 for ${i} = ${r.pick(forms)} do n = n + 1 s = s + ${i} if n > 50 then break end end return n, s end)())`);
    }

    // Arithmetic on strings that convert to numbers.
    s_coerce(scope) {
        const r = this.r;
        const ss = [`"10"`, `"0x10"`, `"1e2"`, `" 7 "`, `"3.0"`, `"-0"`, `"9223372036854775807"`, `"9223372036854775808"`, `"abc"`, `"0x7fffffffffffffff"`, `"1n"`, `"2.5"`];
        const a = r.pick(ss), b = r.pick([...ss, "2", "0.5", "-3"]);
        const op = r.pick(["+", "-", "*", "/", "//", "%", "^", "&", "|", "<<", ".."]);
        const f = this.fresh("co");
        this.emit(`local function ${f}(x, y) return x ${op} y end`);
        this.emit(`for _ = 1, ${r.range(1, 10)} do P("coerce", catch ${f}(${a}, ${b})) end`);
        if (r.chance(0.4)) this.emit(`P("tonum", tonumber(${a}), tonumber(${a}, ${r.pick(["16", "10", "2", "36"])}), math.type(tonumber(${a})))`);
    }

    // Method calls on strings, objects, and tables with methods.
    s_method(scope) {
        const r = this.r;
        const o = this.fresh("mo");
        this.emit(`local ${o} = { n = ${this.literal("int")}, add = function(self, k) self.n = self.n + k return self end, get = function(self) return self.n end }`);
        this.emit(`for i = 1, ${r.range(1, 40)} do ${o}:add(i):add(${this.literal("int")}) end`);
        this.emit(`P("method", ${o}:get(), (${this.expr(scope, "str")}):${r.pick(["upper()", "len()", "rep(2)", "sub(2)", "byte(1)", "reverse()"])})`);
    }

    // Keys that normalize: floats with integral values, bigints, decimals,
    // negative and zero keys, and keys past the array part.
    s_keys(scope) {
        const r = this.r;
        const t = this.fresh("kt");
        this.emit(`local ${t} = {}`);
        this.emit(`for i = 1, ${r.range(1, 30)} do ${t}[i] = i end`);
        const keys = ["1.0", "2n", "3d", "0", "-1", "2^53", "1e300", "\"1\"", "100", "#" + t + " + 1", "0.5", "-0.0", "math.mininteger"];
        for (let k = 0; k < r.range(1, 5); k++) {
            const key = r.pick(keys);
            this.emit(r.chance(0.5) ? `${t}[${key}] = ${this.literal("int")}` : `P("key", ${t}[${key}], rawget(${t}, ${key}))`);
        }
        this.emit(`P("keys", #${t} > 0, ${t}[1], ${t}[2], ${t}[3])`);
    }

    // Recursion deep enough to grow the stack several times, and through
    // varargs and catch.
    s_deep(scope) {
        const r = this.r;
        const f = this.fresh("deep");
        const depth = r.pick(["50", "200", "1000", "3000", "190", "250"]);
        r.weighted([
            [2, () => this.emit(`local function ${f}(n, ...) if n == 0 or n > 2000 then return select("#", ...) end return ${f}(n - 1, n, ...) end`)],
            [2, () => this.emit(`local function ${f}(n) if n == 0 then return 0 end return 1 + ${f}(n - 1) end`)],
            [1, () => this.emit(`local function ${f}(n) if n == 0 then error("bottom") end local ok, e = catch ${f}(n - 1) return n end`)],
            [1, () => this.emit(`local function ${f}(n) if n == 0 then return 0 end return ${f}(n - 1) end`)],
            [1, () => this.emit(`local function ${f}(n) if n <= 0 then return n end return ${f}(n - 1000) end`)],
        ])();
        this.emit(`P("deep", catch ${f}(${depth}))`);
    }

    // Concatenation of many operands of mixed types.
    s_concatn(scope) {
        const n = this.r.range(2, 9);
        const items = [];
        for (let i = 0; i < n; i++) items.push(this.expr(scope, this.r.pick(["str", "int", "float", "str", "big", "dec"])));
        this.emit(`P("cat", catch (${items.join(" .. ")}))`);
    }

    // A chain of __index tables and __newindex handlers.
    s_chain(scope) {
        const r = this.r;
        const base = this.fresh("base"), obj = this.fresh("obj");
        this.emit(`local ${base} = { k = ${this.literal("int")}, m = function(self) return self.k end }`);
        this.emit(`local ${obj} = setmetatable({}, { __index = setmetatable({ j = 2 }, { __index = ${base} }), __newindex = function(t, k, v) rawset(t, k, v * 2) end })`);
        this.emit(`for i = 1, ${r.range(1, 30)} do ${obj}.k = (${obj}.k or 0) + i end`);
        this.emit(`P("chain", ${obj}.k, ${obj}.j, ${obj}:m(), rawget(${obj}, "j"))`);
    }


    // A detached coroutine, which the scheduler runs after the main chunk
    // and resumes round-robin with the others at each yield. It captures
    // locals of the unit, whose upvalues are closed by then.
    s_detach(scope, ctx) {
        const r = this.r;
        this.emit(`if __detached < 8 then`);
        this.indent++;
        this.emit(`__detached = __detached + 1`);
        this.emit(`coroutine.detach(coroutine.create(function(da)`);
        this.indent++;
        this.emit(`local ok, e = catch (function()`);
        this.indent++;
        const inner = new Scope(scope);
        inner.vars.push({ name: "da", type: "int", fixed: true });
        this.emit(`for di = 1, ${r.range(1, 4)} do`);
        this.indent++;
        const ii = new Scope(inner);
        ii.vars.push({ name: "di", type: "int", fixed: true });
        let n = r.range(1, 3);
        while (n-- > 0) this.stmt(ii, { ...ctx, coro: true, func: true, loop: true, ret: "int", depth: ctx.depth + 1 });
        this.emit(`P("detached", da, di, ${this.expr(ii, r.pick(TYPES))})`);
        this.emit(`coroutine.yield()`);
        this.indent--;
        this.emit("end");
        this.emit(`return ${this.expr(inner, "int")}`);
        this.indent--;
        this.emit("end)()");
        this.emit(`P("detached end", da, ok, e)`);
        this.indent--;
        this.emit(`end), ${this.expr(scope, "int")})`);
        this.indent--;
        this.emit("end");
    }


    // Closures made in a loop, each with its own copy of the loop variable,
    // and closures that share one upvalue and write it from a hot loop.
    s_upvals(scope) {
        const r = this.r;
        const fs = this.fresh("fs"), shared = this.fresh("sh"), bump = this.fresh("bump"), n = r.range(2, 40);
        this.emit(`local ${fs}, ${shared} = {}, ${this.literal(r.pick(["int", "float"]))}`);
        this.emit(`local function ${bump}(k) ${shared} = ${shared} ${r.pick(["+", "-", "*"])} k return ${shared} end`);
        this.emit(`for i = 1, ${n} do`);
        this.indent++;
        this.emit(`local own = i * ${r.range(1, 5)}`);
        this.emit(`${fs}[i] = function(d) own = own + d ${shared} = ${shared} + 1 return own end`);
        this.emit(`${bump}(${r.pick(["i", "1", "i % 3", "0.5", "-i"])})`);
        if (r.chance(0.5)) this.emit(`if i % ${r.range(2, 6)} == 0 then ${shared} = ${shared} ${r.pick(["+ 0.5", "* 1", "// 1", "- 1"])} end`);
        this.indent--;
        this.emit("end");
        this.emit(`local ${this.fresh("tot")} = 0`);
        this.emit(`for i = 1, #${fs} do ${shared} = ${shared} + ${fs}[i](i) end`);
        this.emit(`P("upvals", ${shared}, ${fs}[1](0), ${fs}[#${fs}](0))`);
    }

    // Globals read and written in a loop, and a global function called
    // from it, through the inline caches of the globals table.
    s_globals(scope) {
        const r = this.r;
        const g = `G${r.range(1, 4)}`, gf = `GF${r.range(1, 3)}`;
        this.emit(`${gf} = ${gf} or function(x) return (x or 0) ${r.pick(["+", "*", "-"])} ${r.range(1, 9)} end`);
        this.emit(`${g} = ${r.pick(["0", "0.0", "1", g + " or 0"])}`);
        this.emit(`for i = 1, ${r.range(1, 60)} do ${g} = ${gf}(${g}) ${r.pick(["+ i", "- 1", "+ 0.25", "% 1000"])} end`);
        if (r.chance(0.3)) this.emit(`${gf} = function(x) return x end`);
        this.emit(`P("global", ${g}, ${gf}(${this.expr(scope, "int")}))`);
    }

    // A tail-recursive accumulator whose accumulator changes subtype.
    s_tail(scope) {
        const r = this.r;
        const f = this.fresh("tail");
        this.emit(`local function ${f}(n, acc) if n <= 0 then return acc end return ${f}(n - 1, acc ${r.pick(["+ n", "* 1.5", "+ 1n", "- n * 0.5", ".. ''"])}) end`);
        this.emit(`P("tail", catch ${f}(${r.range(0, 300)}, ${this.literal(r.pick(["int", "float", "big"]))}))`);
    }

    // Functions that return several values, used as the last argument, in
    // the middle, in a table constructor, and adjusted to one value.
    s_multiret(scope) {
        const r = this.r;
        const f = this.fresh("mr");
        const n = r.range(0, 4);
        const vals = [];
        for (let i = 0; i < n; i++) vals.push(this.expr(scope, r.pick(["int", "str", "float", "bool"])));
        this.emit(`local function ${f}(k) if k % 2 == 0 then return ${vals.join(", ") || "nil"} end return k, ${vals.join(", ") || "nil"} end`);
        this.emit(`for i = 1, ${r.range(1, 20)} do`);
        this.indent++;
        this.emit(r.pick([
            `P("mr", ${f}(i))`,
            `P("mr", (${f}(i)), ${f}(i))`,
            `P("mr", select("#", ${f}(i)), #{ ${f}(i) }, { ${f}(i), ${f}(i) })`,
            `local a, b, c = ${f}(i) P("mr", a, b, c)`,
            `P("mr", table.pack(${f}(i)).n, ${f}(i + 1))`,
        ]));
        this.indent--;
        this.emit("end");
    }

    // A table that gains a metatable in the middle of a loop, so stores and
    // loads compiled for a plain table meet metamethods.
    s_metaflip(scope) {
        const r = this.r;
        const t = this.fresh("mf"), n = r.range(2, 50), at = r.range(1, n);
        this.emit(`local ${t} = { 1, 2, 3, x = 0 }`);
        this.emit(`for i = 1, ${n} do`);
        this.indent++;
        this.emit(`if i == ${at} then setmetatable(${t}, { __index = function(_, k) return -1 end, __newindex = function(tt, k, v) rawset(tt, k, v) end${r.chance(0.5) ? ", __len = function() return 99 end" : ""} }) end`);
        this.emit(`${t}.x = ${t}.x + (${t}[i + 3] or 0) + #${t}`);
        if (r.chance(0.5)) this.emit(`${t}[i + 10] = i`);
        if (r.chance(0.3)) this.emit(`if i == ${r.range(1, n)} then setmetatable(${t}, nil) end`);
        this.indent--;
        this.emit("end");
        this.emit(`P("metaflip", ${t}.x, #${t}, rawlen(${t}))`);
    }

    // A small function called from a hot loop, the case direct calls and
    // inlining make fast, with arguments whose types change.
    s_hotcall(scope) {
        const r = this.r;
        const f = this.fresh("hc"), acc = this.fresh("acc");
        const inner = new Scope(scope);
        inner.vars.push({ name: "x", type: "int" }, { name: "y", type: "int" });
        this.emit(`local function ${f}(x, y) return ${this.expr(inner, "int", 2)} end`);
        this.emit(`local ${acc} = 0`);
        const arg = r.pick(["i", "i * 1.0", "(i % 3 == 0) and i + 0.5 or i", "-i", "i // 2", "(i > " + r.range(1, 60) + ") and tostring(i) or i"]);
        this.emit(`for i = 1, ${r.range(10, 120)} do ${acc} = ${acc} + (${f}(${arg}, ${this.literal("int")}) or 0) end`);
        this.emit(`P("hotcall", ${acc})`);
    }

    s_if(scope, ctx) {
        this.emit(`if ${this.expr(scope, "bool")} then`);
        this.indent++;
        this.block(scope, 3, { ...ctx, depth: ctx.depth + 1 });
        this.indent--;
        if (this.r.chance(0.3)) {
            this.emit(`elseif ${this.expr(scope, "bool")} then`);
            this.indent++;
            this.block(scope, 2, { ...ctx, depth: ctx.depth + 1 });
            this.indent--;
        }
        if (this.r.chance(0.5)) {
            this.emit("else");
            this.indent++;
            this.block(scope, 2, { ...ctx, depth: ctx.depth + 1 });
            this.indent--;
        }
        this.emit("end");
    }

    s_for(scope, ctx) {
        const r = this.r;
        const i = this.fresh("i");
        const c = { ...ctx, loop: true };
        if (r.chance(0.2)) {
            this.nested(`for ${i} = ${r.pick(["0.5", "1", "-1.5"])}, ${r.range(1, 6)}, ${r.pick(["0.5", "1", "0.25"])} do`, scope, c, "end",
                (s) => s.vars.push({ name: i, type: "float", fixed: true }));
            return;
        }
        const lo = r.range(-3, 3);
        const hi = r.chance(0.3) ? this.expr(scope, "int") + " % 50" : String(r.range(lo, lo + 40));
        const step = r.weighted([[6, ""], [1, ", 2"], [1, ", -1"], [1, ", 3"]]);
        this.nested(`for ${i} = ${lo}, ${hi}${step} do`, scope, c, "end",
            (s) => s.vars.push({ name: i, type: "int", fixed: true }));
    }

    s_forin(scope, ctx) {
        const k = this.fresh("k"), v = this.fresh("v");
        this.nested(`for ${k}, ${v} in ipairs(${this.expr(scope, "arr")}) do`, scope, { ...ctx, loop: true }, "end", (s) => {
            s.vars.push({ name: k, type: "int", fixed: true }, { name: v, type: "int", fixed: true });
        });
    }

    s_while(scope, ctx) {
        const w = this.fresh("w");
        this.emit(`local ${w} = 0`);
        this.nested(`while ${w} < ${this.r.range(1, 30)} and ${this.expr(scope, "bool")} do`, scope, { ...ctx, loop: true }, "end", () => {
            this.emit(`${w} = ${w} + 1`);
        });
    }

    s_repeat(scope, ctx) {
        const w = this.fresh("w");
        this.emit(`local ${w} = 0`);
        this.nested("repeat", scope, { ...ctx, loop: false }, `until ${w} >= ${this.r.range(1, 20)}`, () => {
            this.emit(`${w} = ${w} + 1`);
        });
    }

    s_continue(scope) {
        this.emit(`if ${this.expr(scope, "bool")} then continue end`);
    }

    s_break(scope) {
        this.emit(`if ${this.expr(scope, "bool")} then break end`);
    }

    s_return(scope, ctx) {
        this.emit(`if ${this.expr(scope, "bool")} then return ${this.expr(scope, ctx.ret || "int")} end`);
    }

    s_error(scope) {
        const r = this.r;
        r.weighted([
            [2, () => this.emit(`if ${this.expr(scope, "bool")} then error(${this.expr(scope, "str")}) end`)],
            [1, () => this.emit(`if ${this.expr(scope, "bool")} then error({ code = ${this.expr(scope, "int")} }) end`)],
            [1, () => this.emit(`if ${this.expr(scope, "bool")} then error(${this.expr(scope, "int")}, 0) end`)],
            [1, () => this.emit(`if ${this.expr(scope, "bool")} then local z = nil P(z.field) end`)],
        ])();
    }

    s_yield(scope) {
        this.emit(`coroutine.yield(${this.expr(scope, this.r.pick(TYPES))})`);
    }

    funcBody(header, scope, ctx, params, ret) {
        this.emit(header);
        this.indent++;
        const inner = new Scope(scope);
        for (const p of params) inner.vars.push(p);
        let n = this.r.range(1, 5);
        const c = { ...ctx, func: true, loop: false, ret, depth: ctx.depth + 1 };
        while (n-- > 0) this.stmt(inner, c);
        this.emit(`return ${this.expr(inner, ret)}`);
        this.indent--;
        this.emit("end");
    }

    s_func(scope, ctx) {
        const name = this.fresh("f");
        const params = [];
        const n = this.r.range(0, 3);
        for (let i = 0; i < n; i++) params.push({ name: this.fresh("p"), type: this.r.pick(["int", "int", "str", "float", "arr"]) });
        const ret = this.r.pick(["int", "int", "str", "float", "bool"]);
        const rec = this.r.chance(0.3);
        if (rec) params.push({ name: this.fresh("depth"), type: "int", fixed: true });
        const header = `local function ${name}(${params.map((p) => p.name).join(", ")})`;
        this.emit(header);
        this.indent++;
        const inner = new Scope(scope);
        for (const p of params) inner.vars.push(p);
        if (rec) {
            const dp = params[params.length - 1].name;
            const args = params.slice(0, -1).map((p) => this.expr(inner, p.type));
            this.emit(`if ${dp} > 0 then P("rec", ${dp}, catch ${name}(${[...args, `${dp} - 1`].join(", ")})) end`);
        }
        let k = this.r.range(1, 4);
        const c = { ...ctx, func: true, loop: false, ret, depth: ctx.depth + 1 };
        while (k-- > 0) this.stmt(inner, c);
        this.emit(`return ${this.expr(inner, ret)}`);
        this.indent--;
        this.emit("end");
        const calls = this.r.range(1, 3);
        for (let j = 0; j < calls; j++) {
            const args = params.map((p) => (p.fixed ? String(this.r.range(0, 4)) : this.expr(scope, p.type)));
            const out = this.fresh("r");
            this.emit(`local ${out} = ${name}(${args.join(", ")})`);
            scope.vars.push({ name: out, type: ret });
        }
    }

    s_closure(scope) {
        const mk = this.fresh("mk"), c = this.fresh("cnt"), f = this.fresh("g");
        this.emit(`local function ${mk}(start)`);
        this.indent++;
        this.emit(`local ${c} = start`);
        this.emit(`return function(step) ${c} = ${c} + step return ${c} end, function() return ${c} end`);
        this.indent--;
        this.emit("end");
        const get = this.fresh("get");
        this.emit(`local ${f}, ${get} = ${mk}(${this.expr(scope, "int")})`);
        const n = this.r.range(1, 40);
        this.emit(`for _ = 1, ${n} do ${f}(${this.expr(scope, "int")}) end`);
        this.emit(`P("closure", ${get}())`);
        scope.vars.push({ name: f, type: "fn" });
    }

    s_catch(scope, ctx) {
        const r = this.r;
        const ok = this.fresh("ok"), e = this.fresh("e");
        const handler = r.chance(0.3) ? `[function(m) return { wrapped = m } end]` : "";
        this.emit(`local ${ok}, ${e} = catch${handler} (function()`);
        this.indent++;
        const inner = new Scope(scope);
        let n = r.range(1, 4);
        const c = { ...ctx, func: true, loop: false, ret: "int", depth: ctx.depth + 1 };
        while (n-- > 0) this.stmt(inner, c);
        if (r.chance(0.5)) this.emit(`error(${this.expr(inner, r.pick(["str", "int", "obj"]))}, ${r.pick(["0", "1", "2"])})`);
        this.emit(`return ${this.expr(inner, "int")}`);
        this.indent--;
        this.emit("end)()");
        this.emit(`P("catch", ${ok}, ${e})`);
    }

    s_close(scope, ctx) {
        const c = this.fresh("cl");
        this.nested("do", scope, ctx, "end", () => {
            this.emit(`local ${c} <close> = C(${JSON.stringify(c)})`);
        });
    }

    s_coro(scope, ctx) {
        const r = this.r;
        const co = this.fresh("co");
        const wrap = r.chance(0.5);
        this.emit(`local ${co} = coroutine.${wrap ? "wrap" : "create"}(function(a1, a2)`);
        this.indent++;
        const inner = new Scope(scope);
        inner.vars.push({ name: "a1", type: "int", fixed: true });
        if (r.chance(0.3)) this.emit(`local cc <close> = C(${JSON.stringify(co)})`);
        this.emit(`for yi = 1, ${r.range(1, 6)} do`);
        this.indent++;
        const ii = new Scope(inner);
        ii.vars.push({ name: "yi", type: "int", fixed: true });
        let n = r.range(1, 3);
        while (n-- > 0) this.stmt(ii, { ...ctx, coro: true, func: true, loop: true, ret: "int", depth: ctx.depth + 1 });
        this.emit(`coroutine.yield(yi, ${this.expr(ii, r.pick(TYPES))})`);
        this.indent--;
        this.emit("end");
        this.emit(`return "done", ${this.expr(inner, "int")}`);
        this.indent--;
        this.emit("end)");
        const steps = r.range(1, 9);
        if (wrap) {
            this.emit(`for _ = 1, ${steps} do P("wrap", catch ${co}(${this.expr(scope, "int")})) end`);
        } else {
            this.emit(`for _ = 1, ${steps} do P("resume", coroutine.resume(${co}, ${this.expr(scope, "int")})) end`);
            this.emit(`P("status", coroutine.status(${co}))`);
            if (r.chance(0.3)) this.emit(`P("closeco", coroutine.close(${co}))`);
        }
    }

    s_query(scope) {
        const r = this.r;
        const src = this.fresh("src");
        this.emit(`local ${src} = ${this.expr(scope, "rec")}`);
        const operand = this.varOf(scope, "int") && r.chance(0.5) ? this.varOf(scope, "int") : String(r.range(-2, 12));
        const where = r.chance(0.7) ? ` where p.x ${r.pick([">", "<", ">=", "==", "~="])} ${operand}` : "";
        const sel = r.pick(["select p.x, p.y", "select p.x * 2 as dbl, p.y", "select p", "select p.z, count(*) as n group by p.z"]);
        const order = sel.includes("group by") ? " order by p.z" : r.pick([" order by p.x", " order by p.x desc, p.y", ""]);
        const limit = r.chance(0.3) ? ` limit ${r.range(0, 5)}` : "";
        const row = this.fresh("row");
        if (order === "" && sel.includes("group")) return;
        this.emit(`for ${row} in query(@${src} as p${where} ${sel}${order}${limit}) do P("q", ${row}) end`);
    }

    s_ifassign(scope, ctx) {
        const v = this.fresh("v");
        const a = this.expr(scope, "arr");
        this.nested(`if ${v} = (${a})[${this.expr(scope, "int")} % 5 + 1] then`, scope, ctx, "end",
            (s) => s.vars.push({ name: v, type: "int", fixed: true }));
    }

    s_vararg(scope) {
        const f = this.fresh("va");
        this.emit(`local function ${f}(...)`);
        this.indent++;
        this.emit(`local n = select("#", ...)`);
        this.emit(`local t = table.pack(...)`);
        this.emit(`return n, t.n, select(${this.r.pick(["1", "2", "-1", "\"#\""])}, ...)`);
        this.indent--;
        this.emit("end");
        this.emit(`P("va", catch ${f}(${this.args(scope, 0)}))`);
    }

    s_do(scope) {
        const t = this.r.pick(TYPES);
        const name = this.fresh("dx");
        this.emit(`local ${name} = do`);
        this.indent++;
        this.emit(`if ${this.expr(scope, "bool")} then provide ${this.expr(scope, t)} end`);
        this.emit(`provide ${this.expr(scope, t)}`);
        this.indent--;
        this.emit("end");
        scope.vars.push({ name, type: t });
    }

    s_multi(scope) {
        const ints = scope.all("int").filter((x) => !x.fixed);
        if (ints.length >= 2) {
            const a = this.r.pick(ints).name, b = this.r.pick(ints).name;
            this.emit(`${a}, ${b} = ${b}, ${a}`);
        } else this.s_local(scope);
    }

    s_group(scope) {
        const g = this.fresh("grp");
        this.emit(`local ${g} <group> = { a = ${this.expr(scope, "int")}, b = ${this.expr(scope, "int")} }`);
        this.emit(`${g}.a = ${g}.a + ${g}.b`);
        this.emit(`P("grp", ${g}.a, ${g}.b)`);
    }

    s_goto(scope, ctx) {
        const l = this.fresh("L");
        this.emit("do");
        this.indent++;
        this.emit(`if ${this.expr(scope, "bool")} then goto ${l} end`);
        this.block(scope, 2, { ...ctx, depth: ctx.depth + 1, loop: false });
        this.emit(`::${l}::`);
        this.indent--;
        this.emit("end");
    }

    // ----- program -----

    unit(k) {
        const r = this.r;
        const name = `u${k}`;
        const scope = new Scope(null);
        const params = [];
        const n = r.range(1, 3);
        for (let i = 0; i < n; i++) params.push({ name: `a${k}_${i}`, type: "int" });
        this.emit(`local function ${name}(${params.map((p) => p.name).join(", ")})`);
        this.indent++;
        for (const p of params) scope.vars.push(p);
        let s = r.range(2, this.size);
        while (s-- > 0) this.stmt(scope, { depth: 0, func: true, ret: "int" });
        this.emit(`return ${this.expr(scope, r.pick(TYPES))}`);
        this.indent--;
        this.emit("end");
        // The driving loop. Arguments start as integers and switch type
        // partway, so code compiled for integers meets other values.
        const iters = r.range(3, 160);
        const swap = r.range(1, iters);
        const other = r.pick(["it + 0.5", "it * 1.0", "tostring(it)", "-it", "it * 1000000007", "math.maxinteger - it", "it // 2"]);
        const args = params.map((_, i) => (i === 0 ? `(it < ${swap} and it or ${other})` : `(it * ${r.range(1, 9)} - ${r.range(0, 20)})`));
        this.emit(`for it = 1, ${iters} do P("${name}", it, catch ${name}(${args.join(", ")})) end`);
    }

    program() {
        this.lines.push(PRELUDE.trimEnd());
        const units = this.r.range(1, 4);
        for (let k = 1; k <= units; k++) this.unit(k);
        return this.lines.join("\n") + "\n";
    }
}

export function generate(seed, size = 8) {
    return new Gen(seed, size).program();
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const seed = Number(process.argv[2] ?? 1);
    const i = process.argv.indexOf("--size");
    process.stdout.write(generate(seed, i > 0 ? Number(process.argv[i + 1]) : 8));
}
