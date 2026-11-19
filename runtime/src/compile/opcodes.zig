//! Bytecode format. Every instruction is 32 bits:
//!
//!   iABC:  op:8 A:8 B:8 C:8
//!   iABx:  op:8 A:8 Bx:16
//!   iAsBx: op:8 A:8 sBx:16 (excess-K signed)
//!   isJ:   op:8 sJ:24 (excess-K signed)
//!
//! Register operands address the current frame. `K` operands index the
//! constant table. Quickened variants of generic opcodes share the generic
//! operand layout so the interpreter can rewrite the opcode byte in place.

const std = @import("std");

pub const Op = enum(u8) {
    // Loads and moves
    move, // R[A] = R[B]
    loadk, // R[A] = K[Bx]
    loadi, // R[A] = sBx (integer)
    loadf, // R[A] = sBx (float)
    loadnil, // R[A..A+B] = nil
    loadfalse, // R[A] = false
    loadtrue, // R[A] = true

    // Upvalues and tables
    getupval, // R[A] = Up[B]
    setupval, // Up[B] = R[A]
    gettabup, // R[A] = Up[B][K[C]:string]
    settabup, // Up[A][K[B]:string] = R[C]
    gettable, // R[A] = R[B][R[C]]
    getfield, // R[A] = R[B][K[C]:string]
    getindex, // R[A] = R[B][C] (integer)
    settable, // R[A][R[B]] = R[C]
    setfield, // R[A][K[B]:string] = R[C]
    setindex, // R[A][B] = R[C] (integer)
    newtable, // R[A] = {} with B array slots, C hash slots (log-scaled)
    self, // R[A+1] = R[B]; R[A] = R[B][K[C]:string]

    // Arithmetic on two registers: R[A] = R[B] op R[C]
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    idiv,
    band,
    bor,
    bxor,
    shl,
    shr,
    // Arithmetic with a constant: R[A] = R[B] op K[C]
    addk,
    subk,
    mulk,
    divk,
    modk,
    powk,
    idivk,
    // R[A] = R[B] + sC (C is excess-127 signed)
    addi,

    // Unary
    unm,
    not,
    len,
    bnot,
    concat, // R[A] = R[A] .. ... .. R[A+B-1]
    interp, // R[A] = tostring-concat of R[A..A+B-1] (string interpolation)

    // Control
    jmp, // pc += sJ
    eq, // if ((R[A] == R[B]) ~= C) then pc++
    lt, // if ((R[A] <  R[B]) ~= C) then pc++
    le, // if ((R[A] <= R[B]) ~= C) then pc++
    eqk, // if ((R[A] == K[B]) ~= C) then pc++
    test_, // if (truthy(R[A]) ~= C) then pc++
    testset, // if (truthy(R[B]) ~= C) then pc++ else R[A] = R[B]
    testnil, // if ((R[A] == nil) ~= C) then pc++ (optional chaining)

    call, // R[A], ..., R[A+C-2] = R[A](R[A+1], ..., R[A+B-1])
    tailcall, // return R[A](R[A+1], ..., R[A+B-1])
    ret, // return R[A], ..., R[A+B-2]
    ret0, // return
    ret1, // return R[A]

    forprep, // numeric for: prepare, skip loop if empty (pc += Bx + 1)
    forloop, // numeric for: update, jump back Bx if continuing
    tforprep, // generic for: create tbc for closing value, pc += Bx
    tforcall, // R[A+4], ..., R[A+3+C] = R[A](R[A+1], R[A+2])
    tforloop, // if R[A+4] ~= nil then { R[A+2] = R[A+4]; pc -= Bx }
    rangeprep, // R[A] is the iterator function: if it is the builtin
    // `range`, set up a numeric loop from R[A+1..A+3]; otherwise fall
    // back to the generic for protocol

    setlist, // R[A][C+i] = R[A+i], 1 <= i <= B (B=0: up to top)
    closure, // R[A] = closure(KPROTO[Bx])
    vararg, // R[A], ..., R[A+C-2] = vararg
    varargprep, // adjust varargs on entry (A = number of fixed params)
    close, // close upvalues and tbc variables >= R[A]
    tbc, // mark R[A] as to-be-closed

    // Lus extensions
    slice, // R[A] = R[B][R[B+1], R[B+2]]
    newenum, // R[A] = enum root from constant K[Bx] (a table of names)
    query, // R[A] = query object from plan K[Bx] with sources at R[A+1..]
    checkglobal, // raise if global K[Bx] was not declared (strict mode)

    extraarg, // Ax operand for the previous instruction
};

pub const Instruction = u32;

pub const max_arg_bx = 0xFFFF;
pub const offset_sbx = max_arg_bx >> 1;
pub const max_arg_sj = 0xFFFFFF;
pub const offset_sj = max_arg_sj >> 1;
pub const offset_sc = 127;

pub inline fn op(i: Instruction) Op {
    return @enumFromInt(@as(u8, @truncate(i)));
}
pub inline fn a(i: Instruction) u8 {
    return @truncate(i >> 8);
}
pub inline fn b(i: Instruction) u8 {
    return @truncate(i >> 16);
}
pub inline fn c(i: Instruction) u8 {
    return @truncate(i >> 24);
}
pub inline fn bx(i: Instruction) u16 {
    return @truncate(i >> 16);
}
pub inline fn sbx(i: Instruction) i32 {
    return @as(i32, bx(i)) - offset_sbx;
}
pub inline fn sj(i: Instruction) i32 {
    return @as(i32, @intCast(i >> 8)) - offset_sj;
}
pub inline fn sc(i: Instruction) i32 {
    return @as(i32, c(i)) - offset_sc;
}
pub inline fn ax(i: Instruction) u32 {
    return i >> 8;
}

pub inline fn abc(o: Op, ra: u8, rb: u8, rc: u8) Instruction {
    return @as(u32, @intFromEnum(o)) | (@as(u32, ra) << 8) | (@as(u32, rb) << 16) | (@as(u32, rc) << 24);
}
pub inline fn abx(o: Op, ra: u8, v: u16) Instruction {
    return @as(u32, @intFromEnum(o)) | (@as(u32, ra) << 8) | (@as(u32, v) << 16);
}
pub inline fn asbx(o: Op, ra: u8, v: i32) Instruction {
    return abx(o, ra, @intCast(v + offset_sbx));
}
pub inline fn isj(o: Op, v: i32) Instruction {
    return @as(u32, @intFromEnum(o)) | (@as(u32, @intCast(v + offset_sj)) << 8);
}
pub inline fn iax(o: Op, v: u32) Instruction {
    return @as(u32, @intFromEnum(o)) | (v << 8);
}

pub inline fn setOp(i: *Instruction, o: Op) void {
    i.* = (i.* & 0xFFFFFF00) | @intFromEnum(o);
}
pub inline fn setSj(i: *Instruction, v: i32) void {
    i.* = (i.* & 0xFF) | (@as(u32, @intCast(v + offset_sj)) << 8);
}
pub inline fn setBx(i: *Instruction, v: u16) void {
    i.* = (i.* & 0xFFFF) | (@as(u32, v) << 16);
}
pub inline fn setA(i: *Instruction, v: u8) void {
    i.* = (i.* & 0xFFFF00FF) | (@as(u32, v) << 8);
}
pub inline fn setB(i: *Instruction, v: u8) void {
    i.* = (i.* & 0xFF00FFFF) | (@as(u32, v) << 16);
}
pub inline fn setC(i: *Instruction, v: u8) void {
    i.* = (i.* & 0x00FFFFFF) | (@as(u32, v) << 24);
}

test "encoding round trip" {
    const i = abc(.add, 1, 2, 3);
    try std.testing.expectEqual(Op.add, op(i));
    try std.testing.expectEqual(@as(u8, 3), c(i));
    const j = isj(.jmp, -5);
    try std.testing.expectEqual(@as(i32, -5), sj(j));
    const k = asbx(.loadi, 7, -300);
    try std.testing.expectEqual(@as(i32, -300), sbx(k));
}
