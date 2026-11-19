//! Debug information derived from bytecode: names of variables for error
//! messages ("global 'x'", "local 't'", "field 'f'"), function names for
//! tracebacks, and source positions.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const state = @import("state.zig");
const opc = @import("../compile/opcodes.zig");
const Value = value.Value;
const Proto = object.Proto;
const Thread = state.Thread;

pub const ObjName = struct {
    kind: []const u8,
    name: []const u8,
};

/// Name of the local variable in register `reg` active at `pc`.
pub fn localName(p: *Proto, reg: u32, pc: u32) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (p.locvars) |lv| {
        if (lv.start_pc > pc) continue;
        if (lv.end_pc != 0 and lv.end_pc <= pc) continue;
        if (lv.reg == reg) found = lv.name.bytes();
    }
    // Loop control slots are reported through the instruction that uses
    // them. Other internal names, such as "(attr)", read well as is.
    if (found) |n| if (std.mem.eql(u8, n, "(for state)")) return null;
    return found;
}

fn kString(p: *Proto, idx: u32) ?[]const u8 {
    if (idx >= p.constants.len) return null;
    const k = p.constants[idx];
    if (k.tag != .string) return null;
    return k.as(object.String).bytes();
}

fn upvalName(p: *Proto, idx: u32) []const u8 {
    if (idx < p.upvals.len) if (p.upvals[idx].name) |n| return n.bytes();
    return "?";
}

/// Finds the last instruction before `lastpc` that wrote register `reg`,
/// ignoring jumps that skip over code.
fn findSetReg(p: *Proto, lastpc: u32, reg: u32) ?u32 {
    var setreg: ?u32 = null;
    var jmptarget: u32 = 0;
    var pc: u32 = 0;
    while (pc < lastpc) : (pc += 1) {
        const i = p.code[pc];
        const a: u32 = opc.a(i);
        var change = false;
        switch (opc.op(i)) {
            .loadnil => change = a <= reg and reg <= a + opc.b(i),
            .tforcall => change = reg >= a + 4,
            .call, .tailcall => change = reg >= a,
            .jmp => {
                const dest: i64 = @as(i64, pc) + 1 + opc.sj(i);
                if (dest <= lastpc and dest > jmptarget) jmptarget = @intCast(dest);
            },
            .setupval, .settabup, .settable, .setfield, .setindex, .setlist, .ret, .ret0, .ret1, .eq, .lt, .le, .eqk, .test_, .testnil, .forloop, .tforloop, .close, .tbc, .extraarg, .globaldef, .globaldefr, .catchcheck, .settop, .moverange, .varargprep => {},
            .self => change = reg == a or reg == a + 1,
            else => change = reg == a,
        }
        if (change) setreg = if (pc < jmptarget) null else pc;
    }
    return setreg;
}

pub fn getObjName(p: *Proto, lastpc: u32, reg: u32) ?ObjName {
    if (localName(p, reg, lastpc)) |n| return .{ .kind = "local", .name = n };
    const pc = findSetReg(p, lastpc, reg) orelse return null;
    const i = p.code[pc];
    switch (opc.op(i)) {
        .move => {
            const b = opc.b(i);
            if (b < opc.a(i)) return getObjName(p, pc, b);
        },
        .gettabup => {
            const k = kString(p, opc.c(i)) orelse return null;
            const up = upvalName(p, opc.b(i));
            return .{ .kind = if (std.mem.eql(u8, up, "_ENV")) "global" else "field", .name = k };
        },
        .getfield => {
            const k = kString(p, opc.c(i)) orelse return null;
            const t = opc.b(i);
            if (localName(p, t, pc)) |tn| {
                if (std.mem.eql(u8, tn, "_ENV")) return .{ .kind = "global", .name = k };
            }
            return .{ .kind = "field", .name = k };
        },
        .getupval => return .{ .kind = "upvalue", .name = upvalName(p, opc.b(i)) },
        .getindex => return .{ .kind = "field", .name = "integer index" },
        .loadk => {
            if (kString(p, opc.bx(i))) |s| return .{ .kind = "constant", .name = s };
        },
        .self => {
            const k = kString(p, opc.c(i)) orelse return null;
            return .{ .kind = "method", .name = k };
        },
        else => {},
    }
    return null;
}

/// For an error raised while executing the current instruction of the
/// running Lus frame, finds a description of the register holding `v`.
pub fn varInfo(l: *Thread, v: Value) ?ObjName {
    if (l.frames.items.len == 0) return null;
    const fr = l.frame();
    const cl = fr.closure orelse return null;
    const p = cl.proto;
    if (fr.pc == 0) return null;
    const pc = fr.pc - 1;
    const i = p.code[pc];
    // Candidate registers: the operands of the faulting instruction.
    var cands: [3]u32 = undefined;
    var n: usize = 0;
    switch (opc.op(i)) {
        .tforcall => return .{ .kind = "for iterator", .name = "for iterator" },
        .call, .tailcall => {
            cands[0] = opc.a(i);
            n = 1;
        },
        .getupval, .gettabup => {
            // Indexing an upvalue table: describe the upvalue itself.
            if (opc.op(i) == .gettabup) return .{ .kind = "upvalue", .name = upvalName(p, opc.b(i)) };
            return null;
        },
        .settabup => return .{ .kind = "upvalue", .name = upvalName(p, opc.a(i)) },
        .settable, .setfield, .setindex => {
            cands[0] = opc.a(i);
            n = 1;
        },
        .unm, .bnot, .len, .not, .move => {
            cands[0] = opc.b(i);
            n = 1;
        },
        .forprep => return null,
        .concat => {
            var r: u32 = opc.a(i);
            while (r < opc.a(i) + opc.b(i) and n < 3) : (r += 1) {
                cands[n] = r;
                n += 1;
            }
        },
        else => {
            cands[0] = opc.b(i);
            cands[1] = opc.c(i);
            n = 2;
        },
    }
    for (cands[0..n]) |r| {
        const idx = fr.base + r;
        if (idx < l.stack.len and l.stack[idx].identical(v)) {
            // For CONCAT the faulting operand may differ from the
            // instruction's first register: prefer exact identity.
            if (getObjName(p, pc, r)) |o| return o;
            return null;
        }
    }
    return null;
}

/// Name of the function running in frame `fi` as seen from its caller.
pub fn funcName(l: *Thread, fi: usize) ?ObjName {
    if (fi == 0) return null;
    // A tail call replaced the frame that knew the call site.
    if (l.frames.items[fi].tail) return null;
    const caller = l.frames.items[fi - 1];
    const cl = caller.closure orelse return null;
    if (caller.pc == 0) return null;
    const pc = caller.pc - 1;
    const i = cl.proto.code[pc];
    return switch (opc.op(i)) {
        .call, .tailcall => getObjName(cl.proto, pc, opc.a(i)),
        .tforcall => .{ .kind = "for iterator", .name = "for iterator" },
        else => if (metaEvent(opc.op(i))) |ev| .{ .kind = "metamethod", .name = ev } else null,
    };
}

/// The metamethod event an instruction can trigger, for naming the frame
/// of a metamethod it called.
fn metaEvent(o: opc.Op) ?[]const u8 {
    return switch (o) {
        .add, .addk, .addi => "add",
        .sub, .subk => "sub",
        .mul, .mulk => "mul",
        .div, .divk => "div",
        .mod, .modk => "mod",
        .pow, .powk => "pow",
        .idiv, .idivk => "idiv",
        .band => "band",
        .bor => "bor",
        .bxor => "bxor",
        .shl => "shl",
        .shr => "shr",
        .unm => "unm",
        .bnot => "bnot",
        .len => "len",
        .concat => "concat",
        .eq => "eq",
        .lt => "lt",
        .le => "le",
        .gettable, .getfield, .getindex, .gettabup, .self => "index",
        .settable, .setfield, .setindex, .settabup => "newindex",
        .close, .ret, .ret0, .ret1 => "close",
        else => null,
    };
}

/// Finds `f` among the loaded modules and returns its qualified name
/// ("math.floor", or "next" for a function of the global table), written
/// into `buf`.
pub fn globalName(l: *Thread, f: Value, buf: []u8) ?[]const u8 {
    const table = @import("table.zig");
    const reg = l.g.registry;
    if (reg.tag != .table) return null;
    const loaded = table.getStr(reg.as(object.Table), state.newStringKnown(l.g, "_LOADED", true, 7) catch return null);
    if (loaded.tag != .table) return null;
    var found: ?[]const u8 = null;
    var key: Value = .nil;
    while (table.next(loaded.as(object.Table), key) catch null) |mod| : (key = mod.key) {
        if (mod.key.tag != .string or mod.val.tag != .table) continue;
        var k2: Value = .nil;
        while (table.next(mod.val.as(object.Table), k2) catch null) |e| : (k2 = e.key) {
            if (e.key.tag != .string or !rawSame(e.val, f)) continue;
            const m = mod.key.as(object.String).bytes();
            const n = e.key.as(object.String).bytes();
            // Prefer a library name over the same function in _G.
            if (std.mem.eql(u8, m, "_G")) {
                if (found == null) found = std.fmt.bufPrint(buf, "{s}", .{n}) catch null;
            } else {
                return std.fmt.bufPrint(buf, "{s}.{s}", .{ m, n }) catch null;
            }
        }
    }
    return found;
}

/// Builtins that call sites name by their qualified name, as in
/// "function 'math.floor'". These are the builtins the compiler treats as
/// intrinsics.
const intrinsics = std.StaticStringMap(void).initComptime(.{
    .{"type"},           .{"rawlen"},         .{"rawget"},           .{"rawset"},
    .{"rawequal"},       .{"assert"},         .{"getmetatable"},     .{"setmetatable"},
    .{"tonumber"},       .{"tostring"},       .{"math.abs"},         .{"math.max"},
    .{"math.min"},       .{"math.ceil"},      .{"math.floor"},       .{"math.sqrt"},
    .{"math.sin"},       .{"math.cos"},       .{"math.tan"},         .{"math.asin"},
    .{"math.acos"},      .{"math.atan"},      .{"math.exp"},         .{"math.log"},
    .{"math.deg"},       .{"math.rad"},       .{"math.fmod"},        .{"math.ult"},
    .{"math.tointeger"}, .{"math.type"},      .{"math.ldexp"},       .{"string.len"},
    .{"string.trim"},    .{"string.ltrim"},   .{"string.rtrim"},     .{"string.split"},
    .{"string.join"},    .{"string.sub"},     .{"string.byte"},      .{"string.char"},
    .{"string.lower"},   .{"string.upper"},   .{"string.reverse"},   .{"table.sum"},
    .{"table.mean"},     .{"table.median"},   .{"table.stdev"},      .{"table.transpose"},
    .{"table.reshape"},  .{"vector.create"},  .{"vector.clone"},     .{"vector.size"},
    .{"vector.resize"},  .{"utf8.len"},       .{"utf8.codepoint"},   .{"utf8.char"},
    .{"utf8.offset"},    .{"time.days"},      .{"time.hours"},       .{"time.minutes"},
    .{"time.seconds"},   .{"time.millis"},    .{"time.instant"},
});

/// The qualified name of `f` when it is an intrinsic builtin.
pub fn intrinsicName(l: *Thread, f: Value, buf: []u8) ?[]const u8 {
    if (f.tag != .native) return null;
    const g = globalName(l, f, buf) orelse return null;
    return if (intrinsics.has(g)) g else null;
}

/// How the function running in frame `fi` is named in messages: the
/// intrinsic name, then the name at its call site.
pub fn calleeName(l: *Thread, fi: usize, buf: []u8) ?ObjName {
    if (intrinsicName(l, l.stack[l.frames.items[fi].func], buf)) |q| return .{ .kind = "function", .name = q };
    return funcName(l, fi);
}

fn rawSame(a: Value, b: Value) bool {
    return a.tag == b.tag and a.payload == b.payload;
}

/// Appends a Lua-style traceback of `l`'s frames, innermost first,
/// starting at `level` frames below the top.
pub fn traceback(l: *Thread, buf: *std.ArrayList(u8), level: usize) !void {
    const gpa = l.g.gpa;
    try buf.appendSlice(gpa, "stack traceback:");
    const frames = l.frames.items;
    if (frames.len == 0) return;
    var fi: usize = frames.len - 1 - @min(level, frames.len - 1);
    var shown: usize = 0;
    // The host call below the main chunk counts as one more level.
    const host: usize = if (l == l.g.main_thread) 1 else 0;
    const total = fi + 1 + host;
    var namebuf: [256]u8 = undefined;
    while (true) {
        // Long tracebacks keep the first 10 and last 11 levels. As in the
        // reference implementation, the reported count is one less than
        // the number of levels left out.
        if (total > 22 and shown == 10) {
            try buf.print(gpa, "\n\t...\t(skipping {d} levels)", .{total - 22});
            fi = 10 - host;
        }
        const f = frames[fi];
        try buf.appendSlice(gpa, "\n\t");
        if (f.closure) |cl| {
            const p = cl.proto;
            try buf.print(gpa, "{s}:{d}: in ", .{ state.shortSource(p), state.currentLine(p, f.pc) });
        } else {
            try buf.appendSlice(gpa, "[C]: in ");
        }
        const fval = l.stack[f.func];
        if (calleeName(l, fi, &namebuf)) |n| {
            try buf.print(gpa, "{s} '{s}'", .{ n.kind, n.name });
        } else if (f.closure != null and f.closure.?.proto.line_defined == 0) {
            try buf.appendSlice(gpa, "main chunk");
        } else if (globalName(l, fval, &namebuf)) |g| {
            try buf.print(gpa, "function '{s}'", .{g});
        } else if (f.closure) |cl| {
            try buf.print(gpa, "function <{s}:{d}>", .{ state.shortSource(cl.proto), cl.proto.line_defined });
        } else {
            try buf.appendSlice(gpa, "?");
        }
        if (f.tail) try buf.appendSlice(gpa, "\n\t(...tail calls...)");
        shown += 1;
        if (fi == 0) break;
        fi -= 1;
    }
    // The main thread was entered from the host.
    if (l == l.g.main_thread) try buf.appendSlice(gpa, "\n\t[C]: in ?");
}
