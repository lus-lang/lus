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
    if (found) |n| if (n.len > 0 and n[0] == '(') return null;
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
        .call, .tailcall, .tforcall => {
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
    const caller = l.frames.items[fi - 1];
    const cl = caller.closure orelse return null;
    if (caller.pc == 0) return null;
    const pc = caller.pc - 1;
    const i = cl.proto.code[pc];
    return switch (opc.op(i)) {
        .call, .tailcall => getObjName(cl.proto, pc, opc.a(i)),
        .tforcall => .{ .kind = "for iterator", .name = "for iterator" },
        else => null,
    };
}
