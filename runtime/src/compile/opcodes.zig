//! Bytecode format. Every instruction is 32 bits:
//!
//!   iABC:  op:8 A:8 B:8 C:8
//!   iABx:  op:8 A:8 Bx:16
//!   iAsBx: op:8 A:8 sBx:16 (signed)
//!   isJ:   op:8 sJ:24 (signed)
//!
//! Signed operands are two's complement, and each sits at the top of the
//! word or of its byte, so that one arithmetic shift or one sign-extending
//! field extract decodes it.
//!
//! Register operands address the current frame. `K` operands index the
//! constant table. The compiler chooses specialized instructions and fused
//! pairs, and inline caches and size feedback adapt the generic ones at run
//! time. No instruction rewrites itself.

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
    // R[A] = R[B] + sC (C is signed)
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
    // Comparisons with an integer immediate sB (B is signed)
    lti, // if ((R[A] <  sB) ~= C) then pc++
    lei, // if ((R[A] <= sB) ~= C) then pc++
    gti, // if ((R[A] >  sB) ~= C) then pc++
    gei, // if ((R[A] >= sB) ~= C) then pc++
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

    setlist, // R[A][C+i] = R[A+i], 1 <= i <= B (B=0: up to top)
    closure, // R[A] = closure(KPROTO[Bx])
    vararg, // R[A], ..., R[A+C-2] = vararg
    varargprep, // adjust varargs on entry (A = number of fixed params)
    varargtab, // R[A] = { vararg..., n = #vararg }
    close, // close upvalues and tbc variables >= R[A]
    tbc, // mark R[A] as to-be-closed

    // Lus extensions
    slice, // R[A] = R[B][R[B+1], R[B+2]]
    newenum, // R[A] = enum root from constant K[Bx] (a table of names)
    query, // R[A] = query object from plan K[Bx] with sources at R[A+1..]
    globaldef, // Up[A][K[B]] = R[C], raising if the global is already non-nil
    globaldefr, // R[A][K[B]] = R[C], same check, with a register environment
    catchcheck, // raise if R[A] is not a function (catch handler check)
    settop, // top = base + A (variable results of catch and do expressions)
    moverange, // R[A..] = R[B..top), top = base + A + count

    extraarg, // Ax operand for the previous instruction

    // Context variables (`spec/design/context.md`). R[B] or R[A] holds the
    // slot object of the variable.
    getctx, // R[A] = the value of the variable R[B] in the running coroutine
    setctx, // the value of the variable R[A] in the running coroutine = R[B]
};

/// A fused instruction: two plain instructions that the interpreter runs
/// without a dispatch in between. The first instruction of the pair
/// carries the fused opcode, and the second stays in the code as it is.
/// A jump to the second, a return into it, and every reader other than
/// the interpreter loop therefore see two plain instructions: `op` gives
/// the plain opcode of an instruction, and `code` the one it holds. The
/// set comes from the pairs the bench corpus runs most
/// (`tools/op-ngrams.js`).
pub const Fusion = struct { name: [:0]const u8, first: Op, second: Op };

pub const fusions = [_]Fusion{
    .{ .name = "add_forloop", .first = .add, .second = .forloop },
    .{ .name = "settable_forloop", .first = .settable, .second = .forloop },
    .{ .name = "getupval_subk", .first = .getupval, .second = .subk },
};

const plain_count = @typeInfo(Op).@"enum".field_values.len;

/// The opcode an instruction holds: a plain opcode, with the number and
/// the name it has in `Op`, or a fused one.
pub const Code = blk: {
    const total = plain_count + fusions.len;
    var names: [total][:0]const u8 = undefined;
    var values: [total]u8 = undefined;
    for (@typeInfo(Op).@"enum".field_names, 0..) |n, i| names[i] = n;
    for (fusions, 0..) |f, i| names[plain_count + i] = f.name;
    for (0..total) |i| values[i] = i;
    break :blk @Enum(u8, .exhaustive, &names, &values);
};

/// The plain opcode of every opcode: itself, or the first of the two a
/// fused opcode stands for.
const plain_of: [256]Op = blk: {
    var t: [256]Op = @splat(.extraarg);
    for (0..plain_count) |v| t[v] = @fromBackingInt(v);
    for (fusions, 0..) |f, i| t[plain_count + i] = f.first;
    break :blk t;
};

/// The plain opcode that follows the opcode `o` in the code when `o` is
/// fused, or null.
pub fn fusedWith(o: Code) ?Code {
    const v: usize = @backingInt(o);
    if (v < plain_count) return null;
    return plainCode(fusions[v - plain_count].second);
}

/// The plain opcode `o` as an instruction holds it.
pub inline fn plainCode(o: Op) Code {
    return @fromBackingInt(@backingInt(o));
}

/// True when `byte` is the opcode of an instruction.
pub fn isCode(byte: u8) bool {
    return byte < plain_count + fusions.len;
}

/// Fuses every pair of instructions in `ins` that has a fused opcode.
/// The first instruction of a pair gets the fused opcode, and the second
/// stays, so that the code means the same to every reader of plain
/// opcodes.
pub fn fuse(ins: []Instruction) void {
    if (ins.len < 2) return;
    var i: usize = 0;
    while (i + 1 < ins.len) : (i += 1) {
        for (fusions, 0..) |f, k| {
            if (ins[i] & 0xFF == @backingInt(f.first) and ins[i + 1] & 0xFF == @backingInt(f.second)) {
                ins[i] = (ins[i] & 0xFFFFFF00) | @as(u32, @intCast(plain_count + k));
                // The second instruction starts no pair of its own.
                i += 1;
                break;
            }
        }
    }
}

pub const Instruction = u32;

pub const max_arg_bx = 0xFFFF;
/// The largest magnitude the compiler gives a signed Bx operand.
pub const offset_sbx = max_arg_bx >> 1;
pub const max_arg_sj = 0xFFFFFF;
/// The largest magnitude the compiler gives a jump offset.
pub const offset_sj = max_arg_sj >> 1;
/// The range of a signed B or C operand.
pub const min_sc = -128;
pub const max_sc = 127;

/// The plain opcode of an instruction. A fused instruction reads as the
/// first of its two plain instructions.
pub inline fn op(i: Instruction) Op {
    return plain_of[@as(u8, @truncate(i))];
}
/// The opcode an instruction holds, which is fused or plain. Only the
/// interpreter loop and the listing read it.
pub inline fn code(i: Instruction) Code {
    return @fromBackingInt(@as(u8, @truncate(i)));
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
/// The C operand of a test instruction as a boolean. The compiler writes
/// 0 or 1 there, so one bit holds it.
pub inline fn cond(i: Instruction) bool {
    return i & (1 << 24) != 0;
}
/// True when the test instruction `i`, whose test gave `result`, skips
/// the jump that follows it: the result differs from the C operand. The
/// result is combined with the operand bit in place, which keeps the test
/// to one instruction more than the comparison.
pub inline fn skips(result: bool, i: Instruction) bool {
    return (@intFromBool(result) ^ (i >> 24)) & 1 != 0;
}
pub inline fn bx(i: Instruction) u16 {
    return @truncate(i >> 16);
}
pub inline fn sbx(i: Instruction) i32 {
    return @as(i32, @bitCast(i)) >> 16;
}
pub inline fn sj(i: Instruction) i32 {
    return @as(i32, @bitCast(i)) >> 8;
}
pub inline fn sc(i: Instruction) i32 {
    return @as(i32, @bitCast(i)) >> 24;
}
pub inline fn sb(i: Instruction) i32 {
    return @as(i8, @bitCast(b(i)));
}
/// A signed B or C operand as the byte an instruction holds.
pub inline fn signedByte(v: i64) u8 {
    return @bitCast(@as(i8, @intCast(v)));
}
pub inline fn ax(i: Instruction) u32 {
    return i >> 8;
}

pub inline fn abc(o: Op, ra: u8, rb: u8, rc: u8) Instruction {
    return @as(u32, @backingInt(o)) | (@as(u32, ra) << 8) | (@as(u32, rb) << 16) | (@as(u32, rc) << 24);
}
pub inline fn abx(o: Op, ra: u8, v: u16) Instruction {
    return @as(u32, @backingInt(o)) | (@as(u32, ra) << 8) | (@as(u32, v) << 16);
}
pub inline fn asbx(o: Op, ra: u8, v: i32) Instruction {
    return abx(o, ra, @bitCast(@as(i16, @intCast(v))));
}
pub inline fn isj(o: Op, v: i32) Instruction {
    return @as(u32, @backingInt(o)) | (@as(u32, @bitCast(v)) << 8);
}
pub inline fn iax(o: Op, v: u32) Instruction {
    return @as(u32, @backingInt(o)) | (v << 8);
}

pub inline fn setOp(i: *Instruction, o: Op) void {
    i.* = (i.* & 0xFFFFFF00) | @backingInt(o);
}
pub inline fn setSj(i: *Instruction, v: i32) void {
    i.* = (i.* & 0xFF) | (@as(u32, @bitCast(v)) << 8);
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
    try std.testing.expectEqual(Op.jmp, op(j));
    const far = isj(.jmp, offset_sj);
    try std.testing.expectEqual(@as(i32, offset_sj), sj(far));
    var back = isj(.jmp, 0);
    setSj(&back, -offset_sj);
    try std.testing.expectEqual(@as(i32, -offset_sj), sj(back));
    try std.testing.expectEqual(Op.jmp, op(back));
    const n = asbx(.loadi, 7, -300);
    try std.testing.expectEqual(@as(i32, -300), sbx(n));
    try std.testing.expectEqual(@as(u8, 7), a(n));
    try std.testing.expectEqual(@as(i32, offset_sbx), sbx(asbx(.loadi, 0, offset_sbx)));
    for ([_]i64{ min_sc, -1, 0, 1, max_sc }) |v| {
        try std.testing.expectEqual(@as(i32, @intCast(v)), sc(abc(.addi, 0, 0, signedByte(v))));
        try std.testing.expectEqual(@as(i32, @intCast(v)), sb(abc(.lti, 0, signedByte(v), 1)));
    }
    try std.testing.expect(skips(true, abc(.lti, 0, 0, 0)));
    try std.testing.expect(!skips(true, abc(.lti, 0, 0, 1)));
    try std.testing.expect(skips(false, abc(.lti, 0, 0, 1)));
}

test "fused pairs keep their plain opcodes" {
    var ins = [_]Instruction{
        abc(.getupval, 1, 0, 0),
        abc(.subk, 2, 0, 0),
        abc(.add, 0, 0, 5),
        abx(.forloop, 1, 3),
        abc(.settable, 0, 1, 2),
        abx(.forloop, 1, 5),
        abx(.forloop, 1, 6),
        abc(.add, 0, 0, 1),
    };
    const plain = ins;
    fuse(&ins);
    try std.testing.expectEqualStrings("getupval_subk", @tagName(code(ins[0])));
    try std.testing.expectEqualStrings("subk", @tagName(code(ins[1])));
    try std.testing.expectEqualStrings("add_forloop", @tagName(code(ins[2])));
    try std.testing.expectEqualStrings("settable_forloop", @tagName(code(ins[4])));
    try std.testing.expectEqualStrings("forloop", @tagName(code(ins[6])));
    try std.testing.expectEqualStrings("add", @tagName(code(ins[7])));
    for (ins, plain) |f, p| {
        // Every reader of plain opcodes sees the instructions as written.
        try std.testing.expectEqual(op(p), op(f));
        try std.testing.expectEqual(p >> 8, f >> 8);
        try std.testing.expect(isCode(@truncate(f)));
    }
    try std.testing.expect(fusedWith(code(ins[0])) == plainCode(.subk));
    try std.testing.expect(fusedWith(plainCode(.add)) == null);
    try std.testing.expect(!isCode(@intCast(@typeInfo(Op).@"enum".field_values.len + fusions.len)));
}
