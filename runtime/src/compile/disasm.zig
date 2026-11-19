//! Bytecode listing for `lus --dis` and tests.

const std = @import("std");
const opc = @import("opcodes.zig");
const object = @import("../vm/object.zig");
const ops = @import("../vm/ops.zig");

pub fn dump(gpa: std.mem.Allocator, out: *std.ArrayList(u8), p: *object.Proto, depth: usize) !void {
    try out.print(gpa, "function <{s}:{d}> ({d} instructions, {d} params{s}, {d} slots, {d} upvalues, {d} constants)\n", .{
        if (p.source) |s| s.bytes() else "?", p.line_defined, p.code.len,   p.num_params,
        if (p.is_vararg) "+" else "",         p.max_stack,    p.upvals.len, p.constants.len,
    });
    for (p.code, 0..) |ins, i| {
        const o = opc.op(ins);
        try out.print(gpa, "  {d:>4} [{d:>3}] {s:<12}", .{ i, if (i < p.lines.len) p.lines[i] else 0, @tagName(o) });
        switch (o) {
            .loadk, .closure, .forprep, .forloop, .tforprep, .tforloop => try out.print(gpa, "{d} {d}", .{ opc.a(ins), opc.bx(ins) }),
            .loadi, .loadf => try out.print(gpa, "{d} {d}", .{ opc.a(ins), opc.sbx(ins) }),
            .jmp => try out.print(gpa, "to {d}", .{@as(i64, @intCast(i)) + 1 + opc.sj(ins)}),
            .extraarg => try out.print(gpa, "{d}", .{opc.ax(ins)}),
            .addi => try out.print(gpa, "{d} {d} {d}", .{ opc.a(ins), opc.b(ins), opc.sc(ins) }),
            .lti, .lei, .gti, .gei => try out.print(gpa, "{d} {d} {d}", .{ opc.a(ins), opc.sb(ins), opc.c(ins) }),
            else => try out.print(gpa, "{d} {d} {d}", .{ opc.a(ins), opc.b(ins), opc.c(ins) }),
        }
        try out.append(gpa, '\n');
    }
    for (p.handlers) |h| try out.print(gpa, "  handler [{d}, {d}) -> {d} level {d} dest {d}\n", .{ h.start_pc, h.end_pc, h.handler_pc, h.level, h.dest });
    for (p.protos) |q| try dump(gpa, out, q, depth + 1);
}
