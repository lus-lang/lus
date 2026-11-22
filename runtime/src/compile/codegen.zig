//! Code generator: syntax tree to bytecode prototypes. The expression
//! machinery follows the classic Lua design (expression descriptors,
//! jump lists threaded through JMP instructions, a register stack), with
//! deferred descriptors for `catch` and do-expressions so their result
//! count is known when they are generated.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const opc = @import("opcodes.zig");
const meta = @import("meta.zig");
const lazy = @import("../lib/lazy.zig");
const vm = struct {
    const value = @import("../vm/value.zig");
    const object = @import("../vm/object.zig");
    const state = @import("../vm/state.zig");
    const gc = @import("../vm/gc.zig");
    const numeric = @import("../vm/numeric.zig");
    const ops = @import("../vm/ops.zig");
    const wtf8 = @import("../vm/wtf8.zig");
};
const Value = vm.value.Value;
const Proto = vm.object.Proto;
const Op = opc.Op;
const Allocator = std.mem.Allocator;

pub const Error = error{CompileError} || Allocator.Error;

const no_jump: i32 = -1;
const max_regs = 255;
const max_vars = 200;
const max_upvals = 255;
const lfields_per_flush = 50;

// ---------------------------------------------------------------------
// Expression descriptors

const ExpKind = enum {
    void_,
    nil,
    true_,
    false_,
    k, // info = constant index
    kflt,
    kint,
    kstr, // strval
    nonreloc, // info = register
    local, // info = register, aux = vidx
    upval, // info = upvalue index
    ctc, // info = index into actvars (compile-time constant)
    indexed, // info = table reg, aux = key reg
    indexup, // info = upvalue, aux = K string index
    indexint, // info = table reg, aux = integer key
    indexstr, // info = table reg, aux = K string index
    jmp, // info = pc of the JMP
    reloc, // info = pc of the instruction whose A is unset
    call, // info = pc of CALL
    vararg, // info = pc of VARARG
    deferred, // node = catch or do expression
};

const ExpDesc = struct {
    kind: ExpKind = .void_,
    info: i32 = 0,
    aux: i32 = 0,
    ival: i64 = 0,
    nval: f64 = 0,
    strval: []const u8 = "",
    node: ?*ast.Expr = null,
    t: i32 = no_jump,
    f: i32 = no_jump,

    fn init(kind: ExpKind, info: i32) ExpDesc {
        return .{ .kind = kind, .info = info };
    }
    fn hasJumps(e: ExpDesc) bool {
        return e.t != e.f;
    }
    fn isMulti(e: ExpDesc) bool {
        return e.kind == .call or e.kind == .vararg or e.kind == .deferred;
    }
};

// ---------------------------------------------------------------------
// Variables, blocks, and function state

const VarKind = enum { regular, const_, close, ctc, global_named, global_star, group, lazy };

const VarDesc = struct {
    name: []const u8,
    kind: VarKind,
    readonly: bool = false,
    reg: u8 = 0,
    /// Constant value for compile-time constants.
    k: ExpDesc = .{},
    /// Runtime attribute handler registers (hidden locals).
    handlers: []u8 = &.{},
    /// Group field table for group variables.
    group: ?*Group = null,
    pidx: u32 = 0, // index into locvars debug info
    /// For a `<meta>` local, its value in the meta state, which later
    /// compile-time evaluations receive (`meta.zig`).
    meta_value: ?Value = null,
    /// For a `<meta>` local held in a register (a table or a vector), its
    /// constant value, which folding reads.
    meta_const: ?Value = null,
    /// For a `<lazy>` local, which occupies no register of its own: the
    /// names of the hidden locals that hold its value and its force
    /// function (`lazyLocal`).
    lazy_store: []const u8 = "",
    lazy_force: []const u8 = "",
};

const Group = struct {
    fields: std.StringArrayHashMapUnmanaged(GroupMember) = .empty,
};

const GroupMember = union(enum) {
    field: u32, // index into actvars of the field's local
    sub: *Group,
};

const LabelDesc = struct {
    name: []const u8,
    pc: i32,
    line: u32,
    nactvar: u32,
    close: bool = false,
};

const Block = struct {
    parent: ?*Block,
    first_label: u32,
    first_goto: u32,
    nactvar: u32,
    upval: bool = false,
    is_loop: bool = false,
    inside_tbc: bool = false,
    /// Pending `continue` jumps for loop blocks.
    continues: std.ArrayList(LabelDesc) = .empty,
};

const UpvalInfo = struct {
    name: []const u8,
    in_stack: bool,
    index: u8,
    kind: VarKind,
    readonly: bool,
};

const DoCtx = struct {
    parent: ?*DoCtx,
    base: u8,
    nresults: i32,
    exits: i32 = no_jump,
    nactvar: u32,
};

const FuncState = struct {
    parent: ?*FuncState,
    c: *Compiler,
    f: *ast.Function,
    code: std.ArrayList(u32) = .empty,
    lines: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Value) = .empty,
    kcache: std.HashMapUnmanaged(KKey, u32, KKeyCtx, 80) = .empty,
    protos: std.ArrayList(*Proto) = .empty,
    upvals: std.ArrayList(UpvalInfo) = .empty,
    handlers: std.ArrayList(vm.object.Handler) = .empty,
    locvars: std.ArrayList(vm.object.LocVar) = .empty,
    bl: ?*Block = null,
    first_local: u32,
    first_label: u32,
    first_goto: u32,
    nactvar: u32 = 0,
    freereg: u8 = 0,
    max_stack: u8 = 2,
    last_target: i32 = 0,
    is_vararg: bool = false,
    num_params: u8 = 0,
    needs_close: bool = false,
    do_ctx: ?*DoCtx = null,
    line: u32 = 0,
    /// Lowest register available to new locals. Raised inside a
    /// do-expression body, whose locals sit above the temporaries of the
    /// enclosing expression.
    reg_floor: u8 = 0,
    label_is_last: bool = false,
};

const KKey = struct { tag: u8, bits: u64, str: []const u8 = "" };
const KKeyCtx = struct {
    pub fn hash(_: KKeyCtx, k: KKey) u64 {
        var h = std.hash.Wyhash.init(k.tag);
        h.update(std.mem.asBytes(&k.bits));
        h.update(k.str);
        return h.final();
    }
    pub fn eql(_: KKeyCtx, a: KKey, b: KKey) bool {
        return a.tag == b.tag and a.bits == b.bits and std.mem.eql(u8, a.str, b.str);
    }
};

pub const Options = struct {
    chunkname: []const u8,
    /// Flags table for compile-time folding (`-F`), or null.
    flags: ?*const std.StringHashMapUnmanaged(Value) = null,
    /// Disables optimizations that hide locals from the debugger.
    debug: bool = false,
    /// Replaces every read `flags.NAME` with the value of the flag in
    /// `flags`. The modules of a remote package compile this way, so they
    /// read the flags of their package (`spec/design/modules.md`).
    fold_flag_reads: bool = false,
    /// The permissions of compile-time evaluation (`spec/design/meta.md`).
    meta_grants: meta.Grants = .none,
    /// Whether compile-time evaluation runs. Tools that only check or
    /// format a file turn it off, because opening a file must not run it.
    meta_eval: bool = true,
    /// Set when compiling a compile-time evaluation: the free names that
    /// are locals without a compile-time value in the enclosing code.
    meta_unknown: ?*const std.StringHashMapUnmanaged(void) = null,
};

pub const Compiler = struct {
    gpa: Allocator,
    arena: Allocator,
    g: *vm.state.Global,
    opts: Options,
    /// The meta state of the chunk, created by the first compile-time
    /// evaluation.
    meta: ?*meta.Meta = null,
    /// Above zero while a discarded block or condition compiles. Such code
    /// is checked, never evaluated at compile time.
    discarding: u32 = 0,
    actvars: std.ArrayList(VarDesc) = .empty,
    labels: std.ArrayList(LabelDesc) = .empty,
    gotos: std.ArrayList(LabelDesc) = .empty,
    fs: ?*FuncState = null,
    diag: ?[]const u8 = null,
    source: *vm.object.String = undefined,
    env_name: []const u8 = "_ENV",
    /// Global declaration state of the current name lookup: -1 when no
    /// declaration applies, -2 when a named declaration excludes the name,
    /// or the absolute index of the collective `global *` that covers it.
    ginfo: i32 = -1,

    pub fn err(c: *Compiler, line: u32, comptime fmt: []const u8, args: anytype) Error {
        const name = @import("../syntax/parser.zig").chunkDisplay(c.arena, c.opts.chunkname);
        c.diag = try vm.wtf8.escapeInvalid(c.arena, try std.fmt.allocPrint(c.arena, "{s}:{d}: " ++ fmt, .{ name, line } ++ args));
        return error.CompileError;
    }

    fn newString(c: *Compiler, s: []const u8) Error!*vm.object.String {
        return vm.state.newStringIn(c.g, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return c.err(c.fs.?.line, "invalid UTF-8 in string literal (use a vector for raw bytes)", .{}),
        };
    }
};

// ---------------------------------------------------------------------
// Entry point

/// Compiles a parsed chunk into a main function prototype.
pub fn compileChunk(c: *Compiler, chunk: ast.Chunk) Error!*Proto {
    c.source = try c.newString(c.opts.chunkname);
    const main_fn = try c.arena.create(ast.Function);
    main_fn.* = .{
        .params = &.{},
        .is_vararg = true,
        .body = chunk.block,
        .line = 0,
        .end_line = 0,
        .span = chunk.block.span,
        .name = "main chunk",
    };
    var fs: FuncState = undefined;
    try openFunc(c, &fs, main_fn);
    errdefer abortFunc(c, &fs);
    // The main function has a single upvalue: _ENV.
    try fs.upvals.append(c.gpa, .{ .name = "_ENV", .in_stack = true, .index = 0, .kind = .regular, .readonly = false });
    try codeABC(&fs, .varargprep, 0, 0, 0);
    var bl: Block = undefined;
    enterBlock(&fs, &bl, false);
    try statList(&fs, chunk.block.stats);
    try finalReturn(&fs, chunk.block.end_line);
    try leaveBlock(&fs);
    return closeFunc(c, &fs);
}

fn openFunc(c: *Compiler, fs: *FuncState, f: *ast.Function) Error!void {
    fs.* = .{
        .parent = c.fs,
        .c = c,
        .f = f,
        .first_local = @intCast(c.actvars.items.len),
        .first_label = @intCast(c.labels.items.len),
        .first_goto = @intCast(c.gotos.items.len),
        .line = f.line,
    };
    c.fs = fs;
}

fn closeFunc(c: *Compiler, fs: *FuncState) Error!*Proto {
    const g = c.g;
    const p = try vm.gc.alloc(g, Proto, .proto, @sizeOf(Proto));
    p.* = .{ .hdr = p.hdr };
    p.code = try Proto.allocCode(g.gpa, fs.code.items.len);
    @memcpy(p.code, fs.code.items);
    opc.fuse(p.code);
    try p.initIc(g.gpa);
    p.lines = try g.gpa.dupe(u32, fs.lines.items);
    p.constants = try g.gpa.dupe(Value, fs.constants.items);
    p.link();
    p.protos = try g.gpa.dupe(*Proto, fs.protos.items);
    p.handlers = try g.gpa.dupe(vm.object.Handler, fs.handlers.items);
    p.locvars = try g.gpa.dupe(vm.object.LocVar, fs.locvars.items);
    const ups = try g.gpa.alloc(vm.object.UpvalDesc, fs.upvals.items.len);
    for (fs.upvals.items, 0..) |u, i| {
        ups[i] = .{ .in_stack = u.in_stack, .index = u.index, .name = try c.newString(u.name) };
    }
    p.upvals = ups;
    p.noteCloses();
    p.num_params = fs.num_params;
    p.is_vararg = fs.is_vararg or fs.f.is_vararg;
    p.call.plain = !p.is_vararg;
    p.max_stack = @max(fs.max_stack, 2);
    p.line_defined = fs.f.line;
    p.last_line_defined = fs.f.end_line;
    p.source = c.source;
    if (fs.f.name) |n| p.name = try c.newString(n);
    fs.code.deinit(c.gpa);
    fs.lines.deinit(c.gpa);
    fs.constants.deinit(c.gpa);
    fs.kcache.deinit(c.gpa);
    fs.protos.deinit(c.gpa);
    fs.upvals.deinit(c.gpa);
    fs.handlers.deinit(c.gpa);
    fs.locvars.deinit(c.gpa);
    c.actvars.items.len = fs.first_local;
    c.labels.items.len = fs.first_label;
    c.gotos.items.len = fs.first_goto;
    c.fs = fs.parent;
    return p;
}

// ---------------------------------------------------------------------
// Instruction emission

fn emit(fs: *FuncState, i: u32) Error!i32 {
    try fs.code.append(fs.c.gpa, i);
    try fs.lines.append(fs.c.gpa, fs.line);
    return @intCast(fs.code.items.len - 1);
}

fn codeABC(fs: *FuncState, o: Op, a: u32, b: u32, cc: u32) Error!void {
    _ = try emitABC(fs, o, a, b, cc);
}

fn emitABC(fs: *FuncState, o: Op, a: u32, b: u32, cc: u32) Error!i32 {
    if (a > 255 or b > 255 or cc > 255) return fs.c.err(fs.line, "too many registers (limit is {d}) in {s}", .{ max_regs, whereFunc(fs) });
    return emit(fs, opc.abc(o, @intCast(a), @intCast(b), @intCast(cc)));
}

fn emitABx(fs: *FuncState, o: Op, a: u32, bx: u32) Error!i32 {
    if (bx > opc.max_arg_bx) return fs.c.err(fs.line, "too many constants or functions", .{});
    return emit(fs, opc.abx(o, @intCast(a), @intCast(bx)));
}

fn emitAsBx(fs: *FuncState, o: Op, a: u32, sbx: i32) Error!i32 {
    return emit(fs, opc.asbx(o, @intCast(a), sbx));
}

fn pc(fs: *FuncState) i32 {
    return @intCast(fs.code.items.len);
}

fn getLabel(fs: *FuncState) i32 {
    fs.last_target = pc(fs);
    return pc(fs);
}

fn jump(fs: *FuncState) Error!i32 {
    return emit(fs, opc.isj(.jmp, no_jump));
}

fn getJump(fs: *FuncState, at: i32) i32 {
    const off = opc.sj(fs.code.items[@intCast(at)]);
    if (off == no_jump) return no_jump;
    return at + 1 + off;
}

fn fixJump(fs: *FuncState, at: i32, dest: i32) Error!void {
    const off = dest - (at + 1);
    if (off > opc.offset_sj or off < -opc.offset_sj) return fs.c.err(fs.line, "control structure too long", .{});
    opc.setSj(&fs.code.items[@intCast(at)], off);
}

fn concatJumps(fs: *FuncState, l1: *i32, l2: i32) Error!void {
    if (l2 == no_jump) return;
    if (l1.* == no_jump) {
        l1.* = l2;
        return;
    }
    var list = l1.*;
    while (true) {
        const nxt = getJump(fs, list);
        if (nxt == no_jump) break;
        list = nxt;
    }
    try fixJump(fs, list, l2);
}

/// The control instruction of a jump (the test before it, if any).
fn jumpControl(fs: *FuncState, at: i32) *u32 {
    if (at >= 1) {
        const prev = &fs.code.items[@intCast(at - 1)];
        switch (opc.op(prev.*)) {
            .eq, .lt, .le, .eqk, .lti, .lei, .gti, .gei, .test_, .testset, .testnil => return prev,
            else => {},
        }
    }
    return &fs.code.items[@intCast(at)];
}

/// Patches a TESTSET to store into `reg`, or turns it into a TEST when no
/// value is needed. Returns false when the jump has no TESTSET.
fn patchTestReg(fs: *FuncState, node: i32, reg: u32) bool {
    const i = jumpControl(fs, node);
    if (opc.op(i.*) != .testset) return false;
    if (reg != 255 and reg != opc.b(i.*)) {
        opc.setA(i, @intCast(reg));
    } else {
        i.* = opc.abc(.test_, opc.b(i.*), 0, opc.c(i.*));
    }
    return true;
}

fn removeValues(fs: *FuncState, list: i32) void {
    var l = list;
    while (l != no_jump) : (l = getJump(fs, l)) _ = patchTestReg(fs, l, 255);
}

fn patchListAux(fs: *FuncState, list: i32, vtarget: i32, reg: u32, dtarget: i32) Error!void {
    var l = list;
    while (l != no_jump) {
        const nxt = getJump(fs, l);
        if (patchTestReg(fs, l, reg)) try fixJump(fs, l, vtarget) else try fixJump(fs, l, dtarget);
        l = nxt;
    }
}

fn patchList(fs: *FuncState, list: i32, target: i32) Error!void {
    try patchListAux(fs, list, target, 255, target);
}

fn patchToHere(fs: *FuncState, list: i32) Error!void {
    const here = getLabel(fs);
    try patchList(fs, list, here);
}

// ---------------------------------------------------------------------
// Registers

fn checkStack(fs: *FuncState, n: u32) Error!void {
    const newstack = @as(u32, fs.freereg) + n;
    if (newstack > fs.max_stack) {
        if (newstack > max_regs) return fs.c.err(fs.line, "too many registers (limit is {d}) in {s}", .{ max_regs, whereFunc(fs) });
        fs.max_stack = @intCast(newstack);
    }
}

fn reserveRegs(fs: *FuncState, n: u32) Error!void {
    try checkStack(fs, n);
    fs.freereg += @intCast(n);
}

fn nvarstack(fs: *FuncState) u8 {
    return blockLevel(fs, fs.nactvar);
}

fn inRegister(k: VarKind) bool {
    return switch (k) {
        .regular, .const_, .close => true,
        else => false,
    };
}

fn freeReg(fs: *FuncState, reg: i32) void {
    if (reg >= nvarstack(fs)) {
        fs.freereg -= 1;
        std.debug.assert(reg == fs.freereg);
    }
}

fn freeRegs(fs: *FuncState, r1: i32, r2: i32) void {
    if (r1 > r2) {
        freeReg(fs, r1);
        freeReg(fs, r2);
    } else {
        freeReg(fs, r2);
        freeReg(fs, r1);
    }
}

fn freeExp(fs: *FuncState, e: *const ExpDesc) void {
    if (e.kind == .nonreloc) freeReg(fs, e.info);
}

fn freeExps(fs: *FuncState, e1: *const ExpDesc, e2: *const ExpDesc) void {
    const r1: i32 = if (e1.kind == .nonreloc) e1.info else -1;
    const r2: i32 = if (e2.kind == .nonreloc) e2.info else -1;
    if (r1 >= 0 and r2 >= 0) freeRegs(fs, r1, r2) else if (r1 >= 0) freeReg(fs, r1) else if (r2 >= 0) freeReg(fs, r2);
}

// ---------------------------------------------------------------------
// Constants

fn addK(fs: *FuncState, key: KKey, v: Value) Error!u32 {
    if (fs.kcache.get(key)) |idx| return idx;
    const idx: u32 = @intCast(fs.constants.items.len);
    try fs.constants.append(fs.c.gpa, v);
    try fs.kcache.put(fs.c.gpa, key, idx);
    return idx;
}

fn stringK(fs: *FuncState, s: []const u8) Error!u32 {
    if (fs.kcache.get(.{ .tag = 1, .bits = 0, .str = s })) |idx| return idx;
    const str = try fs.c.newString(s);
    return addK(fs, .{ .tag = 1, .bits = 0, .str = str.bytes() }, Value.obj(.string, str));
}

fn intK(fs: *FuncState, v: i64) Error!u32 {
    return addK(fs, .{ .tag = 2, .bits = @bitCast(v) }, Value.int(v));
}

fn floatK(fs: *FuncState, v: f64) Error!u32 {
    return addK(fs, .{ .tag = 3, .bits = @bitCast(v) }, Value.float(v));
}

fn valueK(fs: *FuncState, v: Value) Error!u32 {
    // Unique heap constants (bigints, decimals, enums) are never shared.
    const idx: u32 = @intCast(fs.constants.items.len);
    try fs.constants.append(fs.c.gpa, v);
    return idx;
}

fn nilK(fs: *FuncState) Error!u32 {
    return addK(fs, .{ .tag = 4, .bits = 0 }, .nil);
}
fn boolK(fs: *FuncState, b: bool) Error!u32 {
    return addK(fs, .{ .tag = 5, .bits = @intFromBool(b) }, Value.boolean(b));
}

fn loadInt(fs: *FuncState, reg: u32, v: i64) Error!void {
    if (v >= -opc.offset_sbx and v <= opc.offset_sbx) {
        _ = try emitAsBx(fs, .loadi, reg, @intCast(v));
    } else {
        _ = try emitABx(fs, .loadk, reg, try intK(fs, v));
    }
}

fn loadFloat(fs: *FuncState, reg: u32, v: f64) Error!void {
    if (v == @floor(v) and v >= -opc.offset_sbx and v <= opc.offset_sbx and !(v == 0 and std.math.signbit(v))) {
        _ = try emitAsBx(fs, .loadf, reg, @intFromFloat(v));
    } else {
        _ = try emitABx(fs, .loadk, reg, try floatK(fs, v));
    }
}

fn loadNil(fs: *FuncState, from: u32, n: u32) Error!void {
    // Merge with a previous LOADNIL when contiguous and no jump targets it.
    if (pc(fs) > fs.last_target and pc(fs) > 0) {
        const prev = &fs.code.items[fs.code.items.len - 1];
        if (opc.op(prev.*) == .loadnil) {
            const pfrom: u32 = opc.a(prev.*);
            const pl = pfrom + opc.b(prev.*);
            const l = from + n - 1;
            if ((pfrom <= from and from <= pl + 1) or (from <= pfrom and pfrom <= l + 1)) {
                const nf = @min(pfrom, from);
                const nl = @max(pl, l);
                prev.* = opc.abc(.loadnil, @intCast(nf), @intCast(nl - nf), 0);
                return;
            }
        }
    }
    try codeABC(fs, .loadnil, from, n - 1, 0);
}

// ---------------------------------------------------------------------
// Discharging expressions

fn setReturns(fs: *FuncState, e: *ExpDesc, nresults: i32) Error!void {
    switch (e.kind) {
        .call => opc.setC(&fs.code.items[@intCast(e.info)], @intCast(nresults + 1)),
        .vararg => {
            const i = &fs.code.items[@intCast(e.info)];
            opc.setC(i, @intCast(nresults + 1));
            opc.setA(i, fs.freereg);
            try reserveRegs(fs, 1);
        },
        .deferred => {
            const base = fs.freereg;
            try genDeferred(fs, e.node.?, base, nresults);
            e.* = ExpDesc.init(.nonreloc, base);
            // Like a call, the expression now owns exactly its first
            // result slot. Callers reserve any further results.
            fs.freereg = base + 1;
        },
        else => {},
    }
}

fn setOneRet(fs: *FuncState, e: *ExpDesc) Error!void {
    switch (e.kind) {
        .call => e.* = ExpDesc.init(.nonreloc, opc.a(fs.code.items[@intCast(e.info)])),
        .vararg => {
            opc.setC(&fs.code.items[@intCast(e.info)], 2);
            e.kind = .reloc;
        },
        .deferred => {
            const base = fs.freereg;
            try genDeferred(fs, e.node.?, base, 1);
            e.* = ExpDesc.init(.nonreloc, base);
        },
        else => {},
    }
}

fn dischargeVars(fs: *FuncState, e: *ExpDesc) Error!void {
    switch (e.kind) {
        .ctc => {
            const v = fs.c.actvars.items[@intCast(e.info)].k;
            e.* = v;
        },
        .local => e.kind = .nonreloc,
        .upval => {
            e.info = try emitABC(fs, .getupval, 0, @intCast(e.info), 0);
            e.kind = .reloc;
        },
        .indexup => {
            e.info = try emitABC(fs, .gettabup, 0, @intCast(e.info), @intCast(e.aux));
            e.kind = .reloc;
        },
        .indexint => {
            freeReg(fs, e.info);
            e.info = try emitABC(fs, .getindex, 0, @intCast(e.info), @intCast(e.aux));
            e.kind = .reloc;
        },
        .indexstr => {
            freeReg(fs, e.info);
            e.info = try emitABC(fs, .getfield, 0, @intCast(e.info), @intCast(e.aux));
            e.kind = .reloc;
        },
        .indexed => {
            freeRegs(fs, e.info, e.aux);
            e.info = try emitABC(fs, .gettable, 0, @intCast(e.info), @intCast(e.aux));
            e.kind = .reloc;
        },
        .vararg, .call, .deferred => try setOneRet(fs, e),
        else => {},
    }
}

fn discharge2reg(fs: *FuncState, e: *ExpDesc, reg: u32) Error!void {
    try dischargeVars(fs, e);
    switch (e.kind) {
        .nil => try loadNil(fs, reg, 1),
        .false_ => try codeABC(fs, .loadfalse, reg, 0, 0),
        .true_ => try codeABC(fs, .loadtrue, reg, 0, 0),
        .kstr => _ = try emitABx(fs, .loadk, reg, try stringK(fs, e.strval)),
        .k => _ = try emitABx(fs, .loadk, reg, @intCast(e.info)),
        .kflt => try loadFloat(fs, reg, e.nval),
        .kint => try loadInt(fs, reg, e.ival),
        .reloc => opc.setA(&fs.code.items[@intCast(e.info)], @intCast(reg)),
        .nonreloc => if (reg != e.info) try codeABC(fs, .move, reg, @intCast(e.info), 0),
        .jmp => return,
        else => unreachable,
    }
    e.info = @intCast(reg);
    e.kind = .nonreloc;
}

fn discharge2anyreg(fs: *FuncState, e: *ExpDesc) Error!void {
    if (e.kind != .nonreloc) {
        try reserveRegs(fs, 1);
        try discharge2reg(fs, e, fs.freereg - 1);
    }
}

fn needValue(fs: *FuncState, list: i32) bool {
    var l = list;
    while (l != no_jump) : (l = getJump(fs, l)) {
        if (opc.op(jumpControl(fs, l).*) != .testset) return true;
    }
    return false;
}

fn codeLoadBool(fs: *FuncState, reg: u32, o: Op) Error!i32 {
    _ = getLabel(fs);
    return emitABC(fs, o, reg, 0, 0);
}

fn exp2reg(fs: *FuncState, e: *ExpDesc, reg: u32) Error!void {
    try discharge2reg(fs, e, reg);
    if (e.kind == .jmp) try concatJumps(fs, &e.t, e.info);
    if (e.hasJumps()) {
        var p_f: i32 = no_jump;
        var p_t: i32 = no_jump;
        if (needValue(fs, e.t) or needValue(fs, e.f)) {
            const fj = if (e.kind == .jmp) no_jump else try jump(fs);
            p_f = try codeLoadBool(fs, reg, .loadfalse);
            // Skip the true load on the false path.
            _ = try emit(fs, opc.isj(.jmp, 1));
            p_t = try codeLoadBool(fs, reg, .loadtrue);
            try patchToHere(fs, fj);
        }
        const final = getLabel(fs);
        try patchListAux(fs, e.f, final, reg, p_f);
        try patchListAux(fs, e.t, final, reg, p_t);
    }
    e.f = no_jump;
    e.t = no_jump;
    e.info = @intCast(reg);
    e.kind = .nonreloc;
}

fn exp2nextreg(fs: *FuncState, e: *ExpDesc) Error!void {
    try dischargeVars(fs, e);
    freeExp(fs, e);
    try reserveRegs(fs, 1);
    try exp2reg(fs, e, fs.freereg - 1);
}

fn exp2anyreg(fs: *FuncState, e: *ExpDesc) Error!u8 {
    try dischargeVars(fs, e);
    if (e.kind == .nonreloc) {
        if (!e.hasJumps()) return @intCast(e.info);
        if (e.info >= nvarstack(fs)) {
            try exp2reg(fs, e, @intCast(e.info));
            return @intCast(e.info);
        }
    }
    try exp2nextreg(fs, e);
    return @intCast(e.info);
}

fn exp2val(fs: *FuncState, e: *ExpDesc) Error!void {
    if (e.hasJumps() or e.kind == .deferred) _ = try exp2anyreg(fs, e) else try dischargeVars(fs, e);
}

fn exp2anyregup(fs: *FuncState, e: *ExpDesc) Error!void {
    if (e.kind != .upval or e.hasJumps()) _ = try exp2anyreg(fs, e);
}

/// Converts a constant expression to a K index if possible.
fn exp2K(fs: *FuncState, e: *ExpDesc) Error!?u32 {
    if (e.hasJumps()) return null;
    return switch (e.kind) {
        .true_ => try boolK(fs, true),
        .false_ => try boolK(fs, false),
        .nil => try nilK(fs),
        .kint => try intK(fs, e.ival),
        .kflt => try floatK(fs, e.nval),
        .kstr => try stringK(fs, e.strval),
        .k => @intCast(e.info),
        else => null,
    };
}

// ---------------------------------------------------------------------
// Stores

fn storeVar(fs: *FuncState, v: *ExpDesc, ex: *ExpDesc) Error!void {
    switch (v.kind) {
        .local => {
            freeExp(fs, ex);
            try exp2reg(fs, ex, @intCast(v.info));
            return;
        },
        .upval => {
            const r = try exp2anyreg(fs, ex);
            try codeABC(fs, .setupval, r, @intCast(v.info), 0);
        },
        .indexup => {
            const r = try exp2anyreg(fs, ex);
            try codeABC(fs, .settabup, @intCast(v.info), @intCast(v.aux), r);
        },
        .indexint => {
            const r = try exp2anyreg(fs, ex);
            try codeABC(fs, .setindex, @intCast(v.info), @intCast(v.aux), r);
        },
        .indexstr => {
            const r = try exp2anyreg(fs, ex);
            try codeABC(fs, .setfield, @intCast(v.info), @intCast(v.aux), r);
        },
        .indexed => {
            const r = try exp2anyreg(fs, ex);
            try codeABC(fs, .settable, @intCast(v.info), @intCast(v.aux), r);
        },
        else => unreachable,
    }
    freeExp(fs, ex);
}

fn isKstr(fs: *FuncState, e: *const ExpDesc) bool {
    _ = fs;
    return e.kind == .kstr and !e.hasJumps();
}

/// Turns `t` (already holding the table) and key `k` into an indexed
/// descriptor.
fn indexed(fs: *FuncState, t: *ExpDesc, k: *ExpDesc) Error!void {
    if (k.kind == .kstr) {
        const ki = try stringK(fs, k.strval);
        if (ki <= 255) {
            if (t.kind == .upval) {
                t.aux = @intCast(ki);
                t.kind = .indexup;
                return;
            }
            const tr = if (t.kind == .local) t.info else t.info;
            t.* = .{ .kind = .indexstr, .info = tr, .aux = @intCast(ki) };
            return;
        }
    }
    if (t.kind == .upval) {
        // Upvalue tables with non-constant keys go through a register.
        _ = try exp2anyreg(fs, t);
    }
    if (k.kind == .kint and k.ival >= 0 and k.ival <= 255 and !k.hasJumps()) {
        t.* = .{ .kind = .indexint, .info = t.info, .aux = @intCast(k.ival) };
        return;
    }
    const kr = try exp2anyreg(fs, k);
    t.* = .{ .kind = .indexed, .info = t.info, .aux = kr };
}

fn codeSelf(fs: *FuncState, e: *ExpDesc, key: []const u8) Error!void {
    _ = try exp2anyreg(fs, e);
    const ereg = e.info;
    freeExp(fs, e);
    e.info = fs.freereg;
    e.kind = .nonreloc;
    try reserveRegs(fs, 2);
    const ki = try stringK(fs, key);
    if (ki <= 255) {
        try codeABC(fs, .self, @intCast(e.info), @intCast(ereg), ki);
    } else {
        // Large constant tables: load the key and index explicitly.
        try codeABC(fs, .move, @intCast(e.info + 1), @intCast(ereg), 0);
        _ = try emitABx(fs, .loadk, @intCast(e.info), ki);
        try codeABC(fs, .gettable, @intCast(e.info), @intCast(e.info + 1), @intCast(e.info));
    }
}

// ---------------------------------------------------------------------
// Conditionals

fn condJump(fs: *FuncState, o: Op, a: u32, b: u32, k: u32) Error!i32 {
    try codeABC(fs, o, a, b, k);
    return jump(fs);
}

fn negateCondition(fs: *FuncState, e: *ExpDesc) void {
    const i = jumpControl(fs, e.info);
    opc.setC(i, opc.c(i.*) ^ 1);
}

fn jumpOnCond(fs: *FuncState, e: *ExpDesc, cond: u32) Error!i32 {
    if (e.kind == .reloc) {
        const ie = fs.code.items[@intCast(e.info)];
        if (opc.op(ie) == .not) {
            fs.code.items.len -= 1;
            fs.lines.items.len -= 1;
            return condJump(fs, .test_, opc.b(ie), 0, cond ^ 1);
        }
    }
    try discharge2anyreg(fs, e);
    freeExp(fs, e);
    return condJump(fs, .testset, 255, @intCast(e.info), cond);
}

fn goIfTrue(fs: *FuncState, e: *ExpDesc) Error!void {
    try dischargeVars(fs, e);
    var pj: i32 = undefined;
    switch (e.kind) {
        .jmp => {
            negateCondition(fs, e);
            pj = e.info;
        },
        .k, .kflt, .kint, .kstr, .true_ => pj = no_jump,
        else => pj = try jumpOnCond(fs, e, 0),
    }
    try concatJumps(fs, &e.f, pj);
    try patchToHere(fs, e.t);
    e.t = no_jump;
}

fn goIfFalse(fs: *FuncState, e: *ExpDesc) Error!void {
    try dischargeVars(fs, e);
    var pj: i32 = undefined;
    switch (e.kind) {
        .jmp => pj = e.info,
        .nil, .false_ => pj = no_jump,
        else => pj = try jumpOnCond(fs, e, 1),
    }
    try concatJumps(fs, &e.t, pj);
    try patchToHere(fs, e.f);
    e.f = no_jump;
}

fn codeNot(fs: *FuncState, e: *ExpDesc) Error!void {
    switch (e.kind) {
        .nil, .false_ => e.kind = .true_,
        .k, .kflt, .kint, .kstr, .true_ => e.kind = .false_,
        .jmp => negateCondition(fs, e),
        .reloc, .nonreloc => {
            try discharge2anyreg(fs, e);
            freeExp(fs, e);
            e.info = try emitABC(fs, .not, 0, @intCast(e.info), 0);
            e.kind = .reloc;
        },
        else => unreachable,
    }
    // Swap true and false lists.
    const tmp = e.f;
    e.f = e.t;
    e.t = tmp;
    removeValues(fs, e.f);
    removeValues(fs, e.t);
}

// ---------------------------------------------------------------------
// Operators

fn isNumeral(e: *const ExpDesc) bool {
    return !e.hasJumps() and (e.kind == .kint or e.kind == .kflt);
}

fn toNumValue(e: *const ExpDesc) Value {
    return if (e.kind == .kint) Value.int(e.ival) else Value.float(e.nval);
}

/// Folds arithmetic on numeric constants when the result is safe to bake
/// into bytecode (no division by zero on integers, no NaN or -0).
fn constFold(fs: *FuncState, op: vm.ops.ArithOp, e1: *ExpDesc, e2: *const ExpDesc) Error!bool {
    if (!isNumeral(e1) or !isNumeral(e2)) return false;
    const a = toNumValue(e1);
    const b = toNumValue(e2);
    switch (op) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            if (vm.ops.toIntegerStrict(a) == null or vm.ops.toIntegerStrict(b) == null) return false;
        },
        .div, .idiv, .mod => if (vm.ops.toFloat(b) == 0) return false,
        else => {},
    }
    const r = (vm.ops.arithRaw(fs.c.g.main_thread, op, a, b) catch return false) orelse return false;
    if (r.tag == .integer) {
        e1.* = .{ .kind = .kint, .ival = r.asInt() };
    } else {
        const f = r.asFloat();
        if (std.math.isNan(f) or f == 0) return false;
        e1.* = .{ .kind = .kflt, .nval = f };
    }
    return true;
}

fn arithOpOf(op: ast.BinOp) ?vm.ops.ArithOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .idiv => .idiv,
        .mod => .mod,
        .pow => .pow,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        else => null,
    };
}

fn arithOpcode(op: vm.ops.ArithOp) Op {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .idiv => .idiv,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        else => unreachable,
    };
}

fn arithKOpcode(op: vm.ops.ArithOp) ?Op {
    return switch (op) {
        .add => .addk,
        .sub => .subk,
        .mul => .mulk,
        .div => .divk,
        .mod => .modk,
        .pow => .powk,
        .idiv => .idivk,
        else => null,
    };
}

/// Prepares the left operand of a binary operator before the right one is
/// generated.
fn infix(fs: *FuncState, op: ast.BinOp, v: *ExpDesc) Error!void {
    try dischargeVars(fs, v);
    switch (op) {
        .@"and" => try goIfTrue(fs, v),
        .@"or" => try goIfFalse(fs, v),
        .concat => try exp2nextreg(fs, v),
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
            if (!isNumeral(v)) _ = try exp2anyreg(fs, v);
        },
        .eq, .ne => {
            // Constants stay operands only when no jumps are pending on them.
            const constant = isNumeral(v) or (!v.hasJumps() and (v.kind == .kstr or v.kind == .nil or v.kind == .true_ or v.kind == .false_));
            if (!constant) _ = try exp2anyreg(fs, v);
        },
        .lt, .le, .gt, .ge => {
            if (!isNumeral(v)) _ = try exp2anyreg(fs, v);
        },
    }
}

fn posfix(fs: *FuncState, op: ast.BinOp, e1: *ExpDesc, e2: *ExpDesc, line: u32) Error!void {
    try dischargeVars(fs, e2);
    fs.line = line;
    switch (op) {
        .@"and" => {
            try concatJumps(fs, &e2.f, e1.f);
            e1.* = e2.*;
        },
        .@"or" => {
            try concatJumps(fs, &e2.t, e1.t);
            e1.* = e2.*;
        },
        .concat => {
            try exp2nextreg(fs, e2);
            // Merge with a CONCAT that the right operand produced.
            const last = &fs.code.items[fs.code.items.len - 1];
            if (opc.op(last.*) == .concat and opc.a(last.*) == e2.info) {
                const n = opc.b(last.*);
                freeExp(fs, e2);
                last.* = opc.abc(.concat, @intCast(e1.info), n + 1, 0);
            } else {
                try codeABC(fs, .concat, @intCast(e1.info), 2, 0);
                freeExp(fs, e2);
            }
        },
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
            const aop = arithOpOf(op).?;
            if (try constFold(fs, aop, e1, e2)) return;
            try codeArith(fs, aop, e1, e2);
        },
        .eq, .ne => try codeEq(fs, op == .eq, e1, e2),
        .lt, .le => try codeOrder(fs, if (op == .lt) .lt else .le, e1, e2),
        .gt, .ge => {
            // a > b is b < a
            try codeOrder(fs, if (op == .gt) .lt else .le, e2, e1);
            e1.* = e2.*;
        },
    }
}

fn codeArith(fs: *FuncState, aop: vm.ops.ArithOp, e1: *ExpDesc, e2: *ExpDesc) Error!void {
    // Integer immediate add.
    if (aop == .add and e2.kind == .kint and !e2.hasJumps() and e2.ival >= opc.min_sc and e2.ival <= opc.max_sc) {
        const r1 = try exp2anyreg(fs, e1);
        freeExp(fs, e1);
        e1.info = try emitABC(fs, .addi, 0, r1, opc.signedByte(e2.ival));
        e1.kind = .reloc;
        return;
    }
    if (arithKOpcode(aop)) |kop| {
        if (isNumeral(e2)) {
            const ki = if (e2.kind == .kint) try intK(fs, e2.ival) else try floatK(fs, e2.nval);
            if (ki <= 255) {
                const r1 = try exp2anyreg(fs, e1);
                freeExp(fs, e1);
                e1.info = try emitABC(fs, kop, 0, r1, ki);
                e1.kind = .reloc;
                return;
            }
        }
    }
    const r2 = try exp2anyreg(fs, e2);
    const r1 = try exp2anyreg(fs, e1);
    freeExps(fs, e1, e2);
    e1.info = try emitABC(fs, arithOpcode(aop), 0, r1, r2);
    e1.kind = .reloc;
}

fn codeEq(fs: *FuncState, is_eq: bool, e1: *ExpDesc, e2: *ExpDesc) Error!void {
    // Constant on the right becomes EQK.
    if (e1.kind != .nonreloc) {
        // swap so that the register operand is first
        const tmp = e1.*;
        e1.* = e2.*;
        e2.* = tmp;
    }
    const r1 = try exp2anyreg(fs, e1);
    if (try exp2K(fs, e2)) |ki| {
        if (ki <= 255) {
            freeExp(fs, e1);
            e1.info = try condJump(fs, .eqk, r1, ki, @intFromBool(is_eq));
            e1.kind = .jmp;
            return;
        }
    }
    const r2 = try exp2anyreg(fs, e2);
    freeExps(fs, e1, e2);
    e1.info = try condJump(fs, .eq, r1, r2, @intFromBool(is_eq));
    e1.kind = .jmp;
}

fn codeOrder(fs: *FuncState, o: Op, e1: *ExpDesc, e2: *ExpDesc) Error!void {
    // A small integer constant on either side becomes an immediate operand.
    if (isSmallInt(e2)) {
        const r1 = try exp2anyreg(fs, e1);
        freeExp(fs, e1);
        e1.info = try condJump(fs, if (o == .lt) .lti else .lei, r1, opc.signedByte(e2.ival), 1);
        e1.kind = .jmp;
        return;
    }
    if (isSmallInt(e1)) {
        const r2 = try exp2anyreg(fs, e2);
        freeExp(fs, e2);
        e1.info = try condJump(fs, if (o == .lt) .gti else .gei, r2, opc.signedByte(e1.ival), 1);
        e1.kind = .jmp;
        return;
    }
    const r1 = try exp2anyreg(fs, e1);
    const r2 = try exp2anyreg(fs, e2);
    freeExps(fs, e1, e2);
    e1.info = try condJump(fs, o, r1, r2, 1);
    e1.kind = .jmp;
}

/// An integer constant that fits the signed immediate of a comparison.
fn isSmallInt(e: *const ExpDesc) bool {
    return e.kind == .kint and !e.hasJumps() and e.ival >= opc.min_sc and e.ival <= opc.max_sc;
}

fn prefix(fs: *FuncState, op: ast.UnOp, e: *ExpDesc, line: u32) Error!void {
    try dischargeVars(fs, e);
    fs.line = line;
    switch (op) {
        .neg, .bnot => {
            const aop: vm.ops.ArithOp = if (op == .neg) .unm else .bnot;
            const zero: ExpDesc = .{ .kind = .kint, .ival = 0 };
            if (try constFold(fs, aop, e, &zero)) return;
            const r = try exp2anyreg(fs, e);
            freeExp(fs, e);
            e.info = try emitABC(fs, if (op == .neg) .unm else .bnot, 0, r, 0);
            e.kind = .reloc;
        },
        .len => {
            const r = try exp2anyreg(fs, e);
            freeExp(fs, e);
            e.info = try emitABC(fs, .len, 0, r, 0);
            e.kind = .reloc;
        },
        .not => try codeNot(fs, e),
    }
}

// ---------------------------------------------------------------------
// Variables and scoping

fn getLocalVar(fs: *FuncState, i: u32) *VarDesc {
    return &fs.c.actvars.items[fs.first_local + i];
}

fn newLocalVar(fs: *FuncState, name: []const u8, kind: VarKind) Error!u32 {
    const c = fs.c;
    if (c.actvars.items.len + 1 - fs.first_local > max_vars) {
        return c.err(fs.line, "too many local variables (limit is {d}) in {s}", .{ max_vars, whereFunc(fs) });
    }
    try c.actvars.append(c.gpa, .{ .name = name, .kind = kind, .readonly = kind == .const_ or kind == .ctc or kind == .close });
    return @intCast(c.actvars.items.len - 1 - fs.first_local);
}

fn whereFunc(fs: *FuncState) []const u8 {
    if (fs.parent == null) return "main function";
    return std.fmt.allocPrint(fs.c.arena, "function at line {d}", .{fs.f.line}) catch "function";
}

/// Activates the last `n` declared variables, assigning registers.
fn adjustLocalVars(fs: *FuncState, n: u32) Error!void {
    var reglevel = nvarstack(fs);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const vidx = fs.nactvar;
        fs.nactvar += 1;
        const v = getLocalVar(fs, vidx);
        if (inRegister(v.kind)) {
            v.reg = reglevel;
            reglevel += 1;
            v.pidx = @intCast(fs.locvars.items.len);
            try fs.locvars.append(fs.c.gpa, .{ .name = try fs.c.newString(v.name), .start_pc = @intCast(pc(fs)), .end_pc = 0, .reg = v.reg });
        }
    }
}

fn removeVars(fs: *FuncState, tolevel: u32) void {
    while (fs.nactvar > tolevel) {
        fs.nactvar -= 1;
        const v = getLocalVar(fs, fs.nactvar);
        if (inRegister(v.kind) and v.pidx < fs.locvars.items.len) {
            fs.locvars.items[v.pidx].end_pc = @intCast(pc(fs));
        }
    }
    fs.c.actvars.items.len = fs.first_local + fs.nactvar;
}

fn enterBlock(fs: *FuncState, bl: *Block, is_loop: bool) void {
    bl.* = .{
        .parent = fs.bl,
        .first_label = @intCast(fs.c.labels.items.len),
        .first_goto = @intCast(fs.c.gotos.items.len),
        .nactvar = fs.nactvar,
        .is_loop = is_loop,
        .inside_tbc = if (fs.bl) |p| p.inside_tbc else false,
    };
    fs.bl = bl;
}

fn leaveBlock(fs: *FuncState) Error!void {
    const bl = fs.bl.?;
    const c = fs.c;
    const stklevel = blockLevel(fs, bl.nactvar);
    removeVars(fs, bl.nactvar);
    var hasclose = false;
    if (bl.is_loop) hasclose = try createLabel(fs, "break", 0, false);
    if (!hasclose and bl.parent != null and bl.upval) {
        try codeABC(fs, .close, stklevel, 0, 0);
    }
    fs.freereg = stklevel;
    c.labels.items.len = bl.first_label;
    fs.bl = bl.parent;
    if (bl.parent) |p| {
        try moveGotosOut(fs, bl, p);
    } else if (bl.first_goto < c.gotos.items.len) {
        const g = c.gotos.items[bl.first_goto];
        if (std.mem.eql(u8, g.name, "break")) return c.err(g.line, "break outside loop", .{});
        if (std.mem.eql(u8, g.name, "continue")) return c.err(g.line, "continue outside loop", .{});
        return c.err(g.line, "no visible label '{s}' for <goto> at line {d}", .{ g.name, g.line });
    }
}

/// Register level of the first local at variable index `nvar`.
fn blockLevel(fs: *FuncState, nvar: u32) u8 {
    var i = nvar;
    while (i > 0) {
        i -= 1;
        const v = getLocalVar(fs, i);
        if (inRegister(v.kind)) return @max(v.reg + 1, fs.reg_floor);
    }
    return fs.reg_floor;
}

fn moveGotosOut(fs: *FuncState, bl: *Block, parent: *Block) Error!void {
    _ = parent;
    const c = fs.c;
    var i = bl.first_goto;
    while (i < c.gotos.items.len) : (i += 1) {
        const g = &c.gotos.items[i];
        if (g.nactvar > bl.nactvar) g.close = g.close or bl.upval;
        g.nactvar = @min(g.nactvar, bl.nactvar);
    }
}

fn createLabel(fs: *FuncState, name: []const u8, line: u32, last: bool) Error!bool {
    const c = fs.c;
    const bl = fs.bl.?;
    const l: LabelDesc = .{ .name = name, .pc = getLabel(fs), .line = line, .nactvar = if (last) bl.nactvar else fs.nactvar };
    try c.labels.append(c.gpa, l);
    if (try solveGotos(fs, l)) {
        try codeABC(fs, .close, nvarstack(fs), 0, 0);
        return true;
    }
    return false;
}

fn solveGotos(fs: *FuncState, l: LabelDesc) Error!bool {
    const c = fs.c;
    const bl = fs.bl.?;
    var needs_close = false;
    var i = bl.first_goto;
    while (i < c.gotos.items.len) {
        const g = c.gotos.items[i];
        if (std.mem.eql(u8, g.name, l.name)) {
            needs_close = needs_close or g.close;
            if (g.nactvar < l.nactvar) {
                const v = getLocalVar(fs, g.nactvar);
                return c.err(g.line, "<goto {s}> at line {d} jumps into the scope of '{s}'", .{ g.name, g.line, v.name });
            }
            try patchList(fs, g.pc, l.pc);
            _ = c.gotos.orderedRemove(i);
        } else i += 1;
    }
    return needs_close;
}

fn newGoto(fs: *FuncState, name: []const u8, line: u32, jpc: i32) Error!void {
    try fs.c.gotos.append(fs.c.gpa, .{ .name = name, .pc = jpc, .line = line, .nactvar = fs.nactvar });
}

// --- name resolution --------------------------------------------------

const SearchResult = union(enum) {
    local: u32, // vidx
    global_named: struct { readonly: bool },
    global_star: struct { readonly: bool },
    none: bool, // true if a named declaration was passed
};

/// Finds `name` among the active variables of `fs`. A collective
/// `global *` does not end the search: it records itself in `ginfo` so an
/// outer local of the same name (such as `_ENV`) still resolves.
fn searchVar(fs: *FuncState, name: []const u8, ginfo: *i32) ?u32 {
    var i = fs.nactvar;
    while (i > 0) {
        i -= 1;
        const v = getLocalVar(fs, i);
        switch (v.kind) {
            .global_named => {
                if (std.mem.eql(u8, v.name, name)) return i;
                if (ginfo.* == -1) ginfo.* = -2;
            },
            .global_star => if (ginfo.* < 0) {
                ginfo.* = @intCast(fs.first_local + i);
            },
            else => if (std.mem.eql(u8, v.name, name)) return i,
        }
    }
    return null;
}

fn markUpval(fs: *FuncState, level: u32) void {
    var bl = fs.bl;
    while (bl) |b| : (bl = b.parent) {
        if (b.nactvar <= level) {
            b.upval = true;
            fs.needs_close = true;
            return;
        }
    }
}

fn searchUpvalue(fs: *FuncState, name: []const u8) ?u32 {
    for (fs.upvals.items, 0..) |u, i| if (std.mem.eql(u8, u.name, name)) return @intCast(i);
    return null;
}

fn newUpvalue(fs: *FuncState, name: []const u8, v: *const ExpDesc) Error!u32 {
    if (fs.upvals.items.len >= max_upvals) return fs.c.err(fs.line, "too many upvalues (limit is {d}) in {s}", .{ max_upvals, whereFunc(fs) });
    const prev = fs.parent.?;
    var info: UpvalInfo = undefined;
    if (v.kind == .local) {
        const vd = getLocalVar(prev, @intCast(v.aux));
        info = .{ .name = name, .in_stack = true, .index = @intCast(v.info), .kind = vd.kind, .readonly = vd.readonly };
    } else {
        const u = prev.upvals.items[@intCast(v.info)];
        info = .{ .name = name, .in_stack = false, .index = @intCast(v.info), .kind = u.kind, .readonly = u.readonly };
    }
    try fs.upvals.append(fs.c.gpa, info);
    return @intCast(fs.upvals.items.len - 1);
}

/// Resolves `name` in function `fs`. Sets `var` to a local, upvalue,
/// compile-time constant, or void (global).
fn singleVarAux(fs: *FuncState, name: []const u8, v: *ExpDesc, base: bool) Error!void {
    if (searchVar(fs, name, &fs.c.ginfo)) |vidx| {
        const vd = getLocalVar(fs, vidx);
        switch (vd.kind) {
            .ctc => {
                v.* = .{ .kind = .ctc, .info = @intCast(fs.first_local + vidx) };
                return;
            },
            .global_named, .global_star => {
                v.* = .{ .kind = .void_, .aux = @intFromBool(vd.readonly), .info = -2 };
                return;
            },
            .group => {
                v.* = .{ .kind = .void_, .info = -3, .aux = @intCast(fs.first_local + vidx) };
                return;
            },
            else => {
                v.* = .{ .kind = .local, .info = vd.reg, .aux = @intCast(vidx) };
                if (!base) markUpval(fs, vidx);
                return;
            },
        }
    }
    // Upvalues already created.
    if (searchUpvalue(fs, name)) |idx| {
        v.* = .{ .kind = .upval, .info = @intCast(idx) };
        return;
    }
    if (fs.parent) |parent| {
        try singleVarAux(parent, name, v, false);
        switch (v.kind) {
            .local, .upval => {
                const idx = try newUpvalue(fs, name, v);
                v.* = .{ .kind = .upval, .info = @intCast(idx) };
            },
            else => {},
        }
        return;
    }
    // Global, or undeclared.
    v.* = .{ .kind = .void_, .info = 0 };
}

/// Builds the descriptor for a variable reference, including `_ENV.name`
/// for globals.
fn singleVar(fs: *FuncState, name: []const u8, line: u32, v: *ExpDesc) Error!void {
    if (knownLocal(fs, name)) |vd| if (vd.kind == .lazy) return lazyRead(fs, vd, line, v);
    fs.c.ginfo = -1;
    try singleVarAux(fs, name, v, true);
    if (v.kind != .void_) return;
    if (std.mem.startsWith(u8, name, lazy.prefix)) if (lazy.number(name[lazy.prefix.len..])) |n| {
        v.* = ExpDesc.init(.k, @intCast(try valueK(fs, try lazy.get(fs.c.g, n))));
        return;
    };
    if (v.info == -3) return; // group: handled by the caller
    const ginfo = fs.c.ginfo;
    if (v.info != -2 and ginfo == -2 and !std.mem.eql(u8, name, "flags") and !std.mem.startsWith(u8, name, "__lus_")) {
        return fs.c.err(line, "variable '{s}' not declared", .{name});
    }
    if (fs.c.opts.meta_unknown) |unknown| if (unknown.contains(name)) {
        return fs.c.err(line, "'{s}' is not known at compile time", .{name});
    };
    const readonly = if (v.info == -2) v.aux != 0 else if (ginfo >= 0) fs.c.actvars.items[@intCast(ginfo)].readonly else false;
    // _ENV.name
    var env: ExpDesc = .{};
    fs.c.ginfo = -1;
    try singleVarAux(fs, fs.c.env_name, &env, true);
    if (env.kind == .void_) return fs.c.err(line, "_ENV is global when accessing variable '{s}'", .{name});
    try exp2anyregup(fs, &env);
    var key: ExpDesc = .{ .kind = .kstr, .strval = name };
    try indexed(fs, &env, &key);
    v.* = env;
    if (readonly or std.mem.eql(u8, name, "flags")) v.node = &readonly_marker;
}

var readonly_marker: ast.Expr = .{ .span = .{ .start = 0, .end = 0 }, .line = 0, .kind = .nil };

fn checkReadonly(fs: *FuncState, v: *const ExpDesc, name: []const u8, line: u32) Error!void {
    if (v.node == &readonly_marker) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{name});
    switch (v.kind) {
        .local => {
            const vd = getLocalVar(fs, @intCast(v.aux));
            if (vd.readonly) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{fieldName(vd.name)});
        },
        .ctc => return fs.c.err(line, "attempt to assign to const variable '{s}'", .{name}),
        .upval => {
            const u = fs.upvals.items[@intCast(v.info)];
            if (u.readonly) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{fieldName(u.name)});
        },
        else => if (v.node == &readonly_marker) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{name}),
    }
}

// ---------------------------------------------------------------------
// Expressions

fn expr(fs: *FuncState, e: *ast.Expr, v: *ExpDesc) Error!void {
    fs.line = e.line;
    switch (e.kind) {
        .nil => v.* = .{ .kind = .nil },
        .true => v.* = .{ .kind = .true_ },
        .false => v.* = .{ .kind = .false_ },
        .integer => |i| v.* = .{ .kind = .kint, .ival = i },
        .float => |f| v.* = .{ .kind = .kflt, .nval = f },
        .string => |s| v.* = .{ .kind = .kstr, .strval = s },
        .bigint => |d| {
            const b = vm.numeric.parseBigLiteral(fs.c.g, d) catch return fs.c.err(e.line, "malformed number near '{s}n'", .{d});
            v.* = ExpDesc.init(.k, @intCast(try valueK(fs, Value.obj(.bigint, b))));
        },
        .decimal => |d| {
            const dv = vm.numeric.parseDecimalLiteral(fs.c.g, d) catch return fs.c.err(e.line, "malformed number near '{s}d'", .{d});
            v.* = ExpDesc.init(.k, @intCast(try valueK(fs, Value.obj(.decimal, dv))));
        },
        .vararg => {
            if (!fs.f.is_vararg) return fs.c.err(e.line, "cannot use '...' outside a vararg function", .{});
            v.* = ExpDesc.init(.vararg, try emitABC(fs, .vararg, 0, 0, 1));
        },
        .interp => |parts| try interpExpr(fs, parts, v),
        .function => |f| try funcExpr(fs, f, v),
        .table => |fields| try tableCtor(fs, fields, v, e.line),
        .binop => |b| {
            if (b.op == .concat) {
                // Flatten right-nested concatenations into one CONCAT.
                try expr(fs, b.lhs, v);
                try infix(fs, .concat, v);
                var e2: ExpDesc = .{};
                try expr(fs, b.rhs, &e2);
                try posfix(fs, .concat, v, &e2, e.line);
                return;
            }
            try expr(fs, b.lhs, v);
            try infix(fs, b.op, v);
            var e2: ExpDesc = .{};
            try expr(fs, b.rhs, &e2);
            try posfix(fs, b.op, v, &e2, e.line);
        },
        .unop => |u| {
            try expr(fs, u.operand, v);
            try prefix(fs, u.op, v, e.line);
        },
        .name => |n| {
            try singleVar(fs, n.text, e.line, v);
            if (v.kind == .void_ and v.info == -3) return fs.c.err(e.line, "cannot pass local group", .{});
        },
        .paren => |inner| {
            try expr(fs, inner, v);
            try dischargeVars(fs, v);
        },
        .index => |ix| {
            if (try groupPath(fs, e, v)) return;
            if (fs.c.opts.fold_flag_reads) if (foldFlagRead(fs, ix.obj, ix.key)) |val| {
                v.* = switch (val.tag) {
                    .nil => .{ .kind = .nil },
                    .true => .{ .kind = .true_ },
                    .false => .{ .kind = .false_ },
                    .integer => .{ .kind = .kint, .ival = val.asInt() },
                    .float => .{ .kind = .kflt, .nval = val.asFloat() },
                    .string => .{ .kind = .kstr, .strval = val.as(vm.object.String).bytes() },
                    else => .{ .kind = .nil },
                };
                return;
            };
            try expr(fs, ix.obj, v);
            try exp2anyregup(fs, v);
            var k: ExpDesc = .{};
            try expr(fs, ix.key, &k);
            try exp2val(fs, &k);
            // An upvalue table indexed by a computed key moves to a
            // register after the key is complete, so the load is not
            // emitted inside the key's pending jumps.
            if (v.kind == .upval and k.kind == .jmp) _ = try exp2anyreg(fs, &k);
            try indexed(fs, v, &k);
        },
        .call => |cl| try callExpr(fs, cl.callee, null, cl.args, v, e.line),
        .method => |m| try callExpr(fs, m.obj, m.name.text, m.args, v, e.line),
        .slice => |s| try sliceExpr(fs, s.obj, s.from, s.to, v),
        .optional => |inner| try optionalExpr(fs, inner, v),
        .chain => |inner| try chainExpr(fs, inner, v),
        .catch_, .do_ => v.* = .{ .kind = .deferred, .node = e },
        .enum_ => |names| try enumExpr(fs, names, v),
        .query => |q| try @import("query_gen.zig").queryExpr(fs, q, v),
    }
}

pub const Internal = struct {
    pub const FS = FuncState;
    pub const Exp = ExpDesc;
    // Helpers for query_gen.zig, which synthesizes clause functions and
    // emits the query instruction.
    pub const BlockCnt = Block;
    pub const genExpr = expr;
    pub const genFunction = funcExpr;
    pub const toNextReg = exp2nextreg;
    pub const reserve = reserveRegs;
    pub const openBlock = enterBlock;
    pub const closeBlock = leaveBlock;
    pub const declareLocal = newLocalVar;
    pub const activateLocals = adjustLocalVars;
    pub const constString = stringK;
    pub const emitBx = emitABx;
    pub const emitAbc = codeABC;
};

fn interpExpr(fs: *FuncState, parts: []ast.InterpPart, v: *ExpDesc) Error!void {
    const base = fs.freereg;
    var n: u32 = 0;
    for (parts) |part| {
        var pe: ExpDesc = .{};
        switch (part) {
            .text => |t| pe = .{ .kind = .kstr, .strval = t },
            .expr => |x| try expr(fs, x, &pe),
        }
        try exp2nextreg(fs, &pe);
        n += 1;
    }
    if (n == 0) {
        v.* = .{ .kind = .kstr, .strval = "" };
        return;
    }
    fs.freereg = base;
    v.info = try emitABC(fs, .interp, base, n, 0);
    v.* = ExpDesc.init(.nonreloc, base);
    try reserveRegs(fs, 1);
}

fn enumExpr(fs: *FuncState, names: []ast.Name, v: *ExpDesc) Error!void {
    const g = fs.c.g;
    const root = try vm.gc.alloc(g, vm.object.EnumRoot, .enum_root, @sizeOf(vm.object.EnumRoot));
    root.names = try g.gpa.alloc(*vm.object.String, names.len);
    root.values = try g.gpa.alloc(?*vm.object.EnumValue, names.len);
    for (names, 0..) |n, i| {
        root.names[i] = try fs.c.newString(n.text);
        root.values[i] = null;
    }
    const first = try vm.gc.alloc(g, vm.object.EnumValue, .enum_value, @sizeOf(vm.object.EnumValue));
    first.root = root;
    first.index = 0;
    root.values[0] = first;
    v.* = ExpDesc.init(.k, @intCast(try valueK(fs, Value.obj(.enum_value, first))));
}

fn sliceExpr(fs: *FuncState, obj: *ast.Expr, from: ?*ast.Expr, to: ?*ast.Expr, v: *ExpDesc) Error!void {
    const base = fs.freereg;
    try expr(fs, obj, v);
    try exp2nextreg(fs, v);
    var e: ExpDesc = .{};
    if (from) |f| try expr(fs, f, &e) else e = .{ .kind = .nil };
    try exp2nextreg(fs, &e);
    if (to) |t| try expr(fs, t, &e) else e = .{ .kind = .nil };
    try exp2nextreg(fs, &e);
    fs.freereg = base;
    v.* = ExpDesc.init(.reloc, try emitABC(fs, .slice, 0, base, 0));
}

/// The register holding the value of the current optional chain, and the
/// jumps that skip the rest of it.
const ChainCtx = struct { jumps: i32 = no_jump, parent: ?*ChainCtx };
threadlocal var chain_ctx: ?*ChainCtx = null;

fn chainExpr(fs: *FuncState, inner: *ast.Expr, v: *ExpDesc) Error!void {
    var ctx: ChainCtx = .{ .parent = chain_ctx };
    chain_ctx = &ctx;
    defer chain_ctx = ctx.parent;
    try expr(fs, inner, v);
    if (ctx.jumps == no_jump) return;
    try exp2nextreg(fs, v);
    // Falsy short-circuit values must end up in the result register.
    const reg = v.info;
    var l = ctx.jumps;
    var same = true;
    while (l != no_jump) : (l = getJump(fs, l)) {
        const t = jumpControl(fs, l);
        if (opc.a(t.*) != reg) same = false;
    }
    if (same) {
        try patchToHere(fs, ctx.jumps);
    } else {
        const skip = try jump(fs);
        // Each test jumps to a MOVE from its own register.
        l = ctx.jumps;
        while (l != no_jump) {
            const nxt = getJump(fs, l);
            const t = jumpControl(fs, l);
            const here = getLabel(fs);
            try fixJump(fs, l, here);
            try codeABC(fs, .move, @intCast(reg), opc.a(t.*), 0);
            const j = try jump(fs);
            try concatJumps(fs, &v.t, j);
            l = nxt;
        }
        try patchToHere(fs, skip);
        try patchToHere(fs, v.t);
        v.t = no_jump;
    }
}

fn optionalExpr(fs: *FuncState, inner: *ast.Expr, v: *ExpDesc) Error!void {
    try expr(fs, inner, v);
    try exp2nextreg(fs, v);
    const ctx = chain_ctx orelse return; // a lone `?` outside a chain
    // Skip the rest of the chain when the value is nil or false.
    const j = try condJump(fs, .test_, @intCast(v.info), 0, 0);
    try concatJumps(fs, &ctx.jumps, j);
}

fn funcExpr(fs: *FuncState, f: *ast.Function, v: *ExpDesc) Error!void {
    const p = try compileFunction(fs.c, f);
    const idx: u32 = @intCast(fs.protos.items.len);
    try fs.protos.append(fs.c.gpa, p);
    v.* = ExpDesc.init(.reloc, try emitABx(fs, .closure, 0, idx));
    try exp2nextreg(fs, v);
}

fn compileFunction(c: *Compiler, f: *ast.Function) Error!*Proto {
    var fs: FuncState = undefined;
    try openFunc(c, &fs, f);
    errdefer abortFunc(c, &fs);
    var bl: Block = undefined;
    enterBlock(&fs, &bl, false);
    var nparams: u32 = 0;
    if (f.is_method) {
        _ = try newLocalVar(&fs, "self", .regular);
        nparams += 1;
    }
    for (f.params) |p| {
        _ = try newLocalVar(&fs, p.text, .regular);
        nparams += 1;
    }
    try adjustLocalVars(&fs, nparams);
    fs.num_params = @intCast(nparams);
    fs.is_vararg = f.is_vararg;
    try reserveRegs(&fs, nparams);
    if (f.is_vararg) {
        try codeABC(&fs, .varargprep, nparams, 0, 0);
        if (f.vararg_name) |vn| {
            // `...t` packs the extra arguments into a table local.
            const vidx = try newLocalVar(&fs, vn.text, .regular);
            _ = vidx;
            const reg = fs.freereg;
            try reserveRegs(&fs, 1);
            try codeABC(&fs, .varargtab, reg, 0, 0);
            try adjustLocalVars(&fs, 1);
        }
    }
    try statList(&fs, f.body.stats);
    fs.line = f.end_line;
    try finalReturn(&fs, f.end_line);
    try leaveBlock(&fs);
    return closeFunc(c, &fs);
}

fn finalReturn(fs: *FuncState, line: u32) Error!void {
    fs.line = line;
    try codeABC(fs, .ret0, 0, 0, 0);
}

fn tableCtor(fs: *FuncState, fields: []ast.Field, v: *ExpDesc, line: u32) Error!void {
    const tpc = try emitABC(fs, .newtable, 0, 0, 0);
    const treg = fs.freereg;
    v.* = ExpDesc.init(.nonreloc, treg);
    opc.setA(&fs.code.items[@intCast(tpc)], treg);
    try reserveRegs(fs, 1);
    var na: u32 = 0; // list items emitted so far
    var nh: u32 = 0;
    var tostore: u32 = 0;
    var pending: ?ExpDesc = null;
    for (fields, 0..) |field, fi| {
        _ = fi;
        if (pending) |*pe| {
            try exp2nextreg(fs, pe);
            pending = null;
            if (tostore == lfields_per_flush) {
                try codeABC(fs, .setlist, treg, tostore, 0);
                _ = try emit(fs, opc.iax(.extraarg, na - tostore));
                tostore = 0;
                fs.freereg = treg + 1;
            }
        }
        switch (field.kind) {
            .positional => |e| {
                var ve: ExpDesc = .{};
                try expr(fs, e, &ve);
                pending = ve;
                na += 1;
                tostore += 1;
            },
            .named => |nf| {
                nh += 1;
                var t: ExpDesc = ExpDesc.init(.nonreloc, treg);
                var k: ExpDesc = .{ .kind = .kstr, .strval = nf.name.text };
                try indexed(fs, &t, &k);
                var val: ExpDesc = .{};
                try expr(fs, nf.value, &val);
                try storeVar(fs, &t, &val);
            },
            .keyed => |kf| {
                nh += 1;
                var t: ExpDesc = ExpDesc.init(.nonreloc, treg);
                var k: ExpDesc = .{};
                try expr(fs, kf.key, &k);
                try exp2val(fs, &k);
                try indexed(fs, &t, &k);
                var val: ExpDesc = .{};
                try expr(fs, kf.value, &val);
                try storeVar(fs, &t, &val);
            },
        }
    }
    if (pending) |*pe| {
        if (pe.isMulti()) {
            try setReturns(fs, pe, -1);
            try codeABC(fs, .setlist, treg, 0, 0);
            _ = try emit(fs, opc.iax(.extraarg, na - tostore));
            na -= 1;
            tostore = 0;
        } else {
            try exp2nextreg(fs, pe);
        }
    }
    if (tostore > 0) {
        try codeABC(fs, .setlist, treg, tostore, 0);
        _ = try emit(fs, opc.iax(.extraarg, na - tostore));
    }
    fs.freereg = treg + 1;
    _ = line;
    // Size hints.
    opc.setB(&fs.code.items[@intCast(tpc)], @intCast(@min(na, 255)));
    opc.setC(&fs.code.items[@intCast(tpc)], @intCast(@min(nh, 255)));
}

fn callExpr(fs: *FuncState, callee: *ast.Expr, method: ?[]const u8, args: []*ast.Expr, v: *ExpDesc, line: u32) Error!void {
    try expr(fs, callee, v);
    if (method) |m| {
        try codeSelf(fs, v, m);
    } else {
        try exp2nextreg(fs, v);
    }
    const base = v.info;
    var nparams: i32 = undefined;
    if (args.len == 0) {
        nparams = 0;
    } else {
        var last: ExpDesc = .{};
        for (args, 0..) |a, i| {
            try expr(fs, a, &last);
            if (i + 1 < args.len) try exp2nextreg(fs, &last);
        }
        if (last.isMulti()) {
            try setReturns(fs, &last, -1);
            nparams = -1;
        } else {
            try exp2nextreg(fs, &last);
        }
    }
    if (nparams != -1) nparams = @as(i32, fs.freereg) - (base + 1);
    fs.line = line;
    const b: u32 = if (nparams == -1) 0 else @intCast(nparams + 1);
    v.* = ExpDesc.init(.call, try emitABC(fs, .call, @intCast(base), b, 2));
    fs.freereg = @intCast(base + 1);
    // Calls inside an optional chain yield exactly one value.
    if (chain_ctx != null) try setOneRet(fs, v);
}

/// Describes the field local `vabs` of a local group as seen from `fs`. A
/// field of a group declared in an enclosing function is reached through an
/// upvalue, created on each function level between the two as needed.
fn groupField(fs: *FuncState, vabs: u32, v: *ExpDesc) Error!void {
    const fvd = &fs.c.actvars.items[vabs];
    if (fvd.kind == .lazy) return lazyRead(fs, fvd, fs.line, v);
    if (vabs >= fs.first_local) {
        const vidx = vabs - fs.first_local;
        v.* = .{ .kind = .local, .info = getLocalVar(fs, vidx).reg, .aux = @intCast(vidx) };
        return;
    }
    const parent = fs.parent.?;
    try groupField(parent, vabs, v);
    if (v.kind == .local) markUpval(parent, @intCast(v.aux));
    const in_stack = v.kind == .local;
    const index: u8 = @intCast(v.info);
    for (fs.upvals.items, 0..) |u, i| {
        if (u.in_stack == in_stack and u.index == index) {
            v.* = .{ .kind = .upval, .info = @intCast(i) };
            return;
        }
    }
    const idx = try newUpvalue(fs, fs.c.actvars.items[vabs].name, v);
    v.* = .{ .kind = .upval, .info = @intCast(idx) };
}

/// Resolves `g.f` paths of local groups. Returns true when `e` was a group
/// path and `v` now describes the field local.
fn groupPath(fs: *FuncState, e: *ast.Expr, v: *ExpDesc) Error!bool {
    // Collect the path root and field names.
    var names: [32][]const u8 = undefined;
    var n: usize = 0;
    var cur = e;
    while (true) {
        switch (cur.kind) {
            .index => |ix| {
                if (!ix.dot or n >= names.len) return false;
                names[n] = ix.key.kind.string;
                n += 1;
                cur = ix.obj;
            },
            .name => break,
            else => return false,
        }
    }
    const root_name = cur.kind.name.text;
    var rv: ExpDesc = .{};
    try singleVarAux(fs, root_name, &rv, true);
    var group: *Group = undefined;
    if (rv.kind == .void_ and rv.info == -3) {
        group = fs.c.actvars.items[@intCast(rv.aux)].group.?;
    } else return false;
    // Walk fields from the root outward. names[] is reversed.
    var i = n;
    while (i > 0) {
        i -= 1;
        const fname = names[i];
        const m = group.fields.get(fname) orelse return fs.c.err(e.line, "'{s}' is not a field of group '{s}'", .{ fname, root_name });
        switch (m) {
            .sub => |sg| {
                if (i == 0) return fs.c.err(e.line, "cannot pass local group", .{});
                group = sg;
            },
            .field => |vabs| {
                try groupField(fs, vabs, v);
                if (i > 0) {
                    // Remaining names index into the field's value.
                    var j = i;
                    while (j > 0) {
                        j -= 1;
                        try exp2anyregup(fs, v);
                        var k: ExpDesc = .{ .kind = .kstr, .strval = names[j] };
                        try indexed(fs, v, &k);
                    }
                }
                return true;
            },
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Deferred expressions: catch and do

fn genDeferred(fs: *FuncState, e: *ast.Expr, base: u8, nresults: i32) Error!void {
    switch (e.kind) {
        .catch_ => |c| try genCatch(fs, c, base, nresults),
        .do_ => |b| try genDo(fs, b, base, nresults, e.line),
        else => unreachable,
    }
}

/// Generates `catch [h] body` with results starting at `base`. On
/// success: true followed by the body's values. On failure: false and the
/// error (after the handler, when present).
fn genCatch(fs: *FuncState, c: ast.Catch, base: u8, nresults: i32) Error!void {
    std.debug.assert(fs.freereg == base);
    try reserveRegs(fs, 1); // status slot
    // The handler is evaluated first, outside the protection, into the
    // status slot. The success path overwrites it with `true`.
    const has_handler = c.handler != null;
    if (c.handler) |h| {
        var he: ExpDesc = .{};
        try expr(fs, h, &he);
        try exp2reg(fs, &he, base);
        // The handler lives only in the status slot. Release any temporary
        // its evaluation left behind so the values start right after it.
        fs.freereg = base + 1;
        try codeABC(fs, .catchcheck, base, 0, 0);
    }
    const vals: u8 = base + 1; // first value slot
    const body_start = pc(fs);
    var be: ExpDesc = .{};
    try expr(fs, c.body, &be);
    if (nresults < 0) {
        if (be.isMulti()) {
            try setReturns(fs, &be, -1);
        } else {
            try exp2nextreg(fs, &be);
            try codeABC(fs, .settop, vals + 1, 0, 0);
        }
    } else {
        const want_vals: i32 = @max(nresults - 1, 0);
        if (be.isMulti()) {
            const b0 = fs.freereg;
            try setReturns(fs, &be, want_vals);
            fs.freereg = b0;
        } else {
            try exp2nextreg(fs, &be);
            if (want_vals > 1) try loadNil(fs, vals + 1, @intCast(want_vals - 1));
        }
    }
    const body_end = pc(fs);
    try codeABC(fs, .loadtrue, base, 0, 0);
    const done = try jump(fs);
    // Error path: the unwinder stores the error in `vals`.
    const handler_pc = getLabel(fs);
    try fs.handlers.append(fs.c.gpa, .{
        .start_pc = @intCast(body_start),
        .end_pc = @intCast(body_end),
        .handler_pc = @intCast(handler_pc),
        .level = vals,
        .dest = vals,
    });
    if (has_handler) {
        // vals = handler(err)
        try checkStack(fs, 3);
        try codeABC(fs, .move, vals + 1, vals, 0);
        try codeABC(fs, .move, vals, base, 0);
        try codeABC(fs, .call, vals, 2, 2);
    }
    try codeABC(fs, .loadfalse, base, 0, 0);
    if (nresults < 0) try codeABC(fs, .settop, vals + 1, 0, 0);
    if (nresults > 2) try loadNil(fs, @as(u32, base) + 2, @intCast(nresults - 2));
    try patchToHere(fs, done);
    fs.freereg = base;
    if (nresults < 0) {
        try reserveRegs(fs, 1);
    } else {
        try reserveRegs(fs, @intCast(@max(nresults, 1)));
    }
}

fn genDo(fs: *FuncState, b: *ast.Block, base: u8, nresults: i32, line: u32) Error!void {
    std.debug.assert(fs.freereg == base);
    const want: u32 = if (nresults < 0) 1 else @intCast(@max(nresults, 1));
    try reserveRegs(fs, want);
    try loadNil(fs, base, want);
    var ctx: DoCtx = .{ .parent = fs.do_ctx, .base = base, .nresults = nresults, .nactvar = fs.nactvar };
    fs.do_ctx = &ctx;
    const saved_floor = fs.reg_floor;
    fs.reg_floor = fs.freereg;
    defer fs.reg_floor = saved_floor;
    var bl: Block = undefined;
    enterBlock(fs, &bl, false);
    try statList(fs, b.stats);
    try leaveBlock(fs);
    fs.do_ctx = ctx.parent;
    // Falling off the end produces a single nil.
    if (nresults < 0) try codeABC(fs, .settop, base + 1, 0, 0);
    try patchToHere(fs, ctx.exits);
    fs.freereg = base;
    try reserveRegs(fs, want);
    _ = line;
}

fn provideStat(fs: *FuncState, vals: []*ast.Expr, line: u32) Error!void {
    const ctx = fs.do_ctx.?;
    const saved = fs.freereg;
    // Evaluate into fresh registers, then move to the result slots.
    const first = fs.freereg;
    var n: i32 = 0;
    var multi = false;
    for (vals, 0..) |ve, i| {
        var e: ExpDesc = .{};
        try expr(fs, ve, &e);
        if (i + 1 == vals.len and e.isMulti() and ctx.nresults < 0) {
            try setReturns(fs, &e, -1);
            multi = true;
        } else if (i + 1 == vals.len and e.isMulti() and ctx.nresults > n) {
            // A trailing call fills every remaining fixed result.
            const extra = ctx.nresults - n;
            try setReturns(fs, &e, extra);
            if (e.kind == .call) e = ExpDesc.init(.nonreloc, opc.a(fs.code.items[@intCast(e.info)]));
            if (extra > 1) try reserveRegs(fs, @intCast(extra - 1));
            n += extra;
        } else {
            try exp2nextreg(fs, &e);
            n += 1;
        }
    }
    // Close upvalues and tbc variables of the do body while the provided
    // values still sit above them, then move the values into place.
    const level = blockLevel(fs, ctx.nactvar);
    if (level < first) try codeABC(fs, .close, @max(level, ctx.base + 1), 0, 0);
    const want = ctx.nresults;
    if (want < 0) {
        if (multi) {
            // Fixed values sit from `first`, the variable tail runs to top:
            // shift all of them down to base.
            try codeABC(fs, .moverange, ctx.base, first, 0);
        } else {
            var i: u32 = 0;
            while (i < n) : (i += 1) try codeABC(fs, .move, ctx.base + i, first + i, 0);
            if (n == 0) try loadNil(fs, ctx.base, 1);
            try codeABC(fs, .settop, ctx.base + @as(u32, @intCast(@max(n, 1))), 0, 0);
        }
    } else {
        var i: u32 = 0;
        while (i < want) : (i += 1) {
            if (i < n) try codeABC(fs, .move, ctx.base + i, first + i, 0) else try loadNil(fs, ctx.base + i, 1);
        }
    }
    const j = try jump(fs);
    try concatJumps(fs, &ctx.exits, j);
    fs.freereg = saved;
    _ = line;
}

// ---------------------------------------------------------------------
// Statements

fn statList(fs: *FuncState, stats: []*ast.Stat) Error!void {
    for (stats, 0..) |s, i| {
        // A label followed only by empty statements and other labels up
        // to the end of its block is outside the scope of the block's
        // locals, so forward gotos may jump to it.
        if (s.kind == .label) {
            var last = true;
            for (stats[i + 1 ..]) |rest| switch (rest.kind) {
                .empty, .label => {},
                else => {
                    last = false;
                    break;
                },
            };
            fs.label_is_last = last;
        }
        try statement(fs, s);
    }
}

fn block(fs: *FuncState, b: *ast.Block) Error!void {
    var bl: Block = undefined;
    enterBlock(fs, &bl, false);
    try statList(fs, b.stats);
    try leaveBlock(fs);
}

fn statement(fs: *FuncState, s: *ast.Stat) Error!void {
    fs.line = s.line;
    switch (s.kind) {
        .empty, .recovered => {},
        .expr => |e| {
            var v: ExpDesc = .{};
            try expr(fs, e, &v);
            if (v.kind == .call) opc.setC(&fs.code.items[@intCast(v.info)], 1);
        },
        .local => |l| try localStat(fs, l.names, l.values, s.line),
        .local_from => |l| try localFrom(fs, l.names, l.source, s.line),
        .local_group => |l| try localGroup(fs, l.names, l.inits, s.line),
        .local_function => |lf| {
            _ = try newLocalVar(fs, lf.name.text, .regular);
            try adjustLocalVars(fs, 1);
            var v: ExpDesc = .{};
            try funcExpr(fs, lf.func, &v);
            // The function now lives in the local's register.
            const vd = getLocalVar(fs, fs.nactvar - 1);
            if (vd.pidx < fs.locvars.items.len) fs.locvars.items[vd.pidx].start_pc = @intCast(pc(fs));
        },
        .global => |gd| try globalStat(fs, gd.default_attribs, gd.names, gd.values, gd.star, s.line),
        .global_from => |gf| try globalFrom(fs, gf.default_attribs, gf.names, gf.source, s.line),
        .global_function => |gf| {
            try declareGlobals(fs, &.{}, &.{.{ .name = gf.name }}, s.line);
            var v: ExpDesc = .{};
            try funcExpr(fs, gf.func, &v);
            try globalDefine(fs, gf.name.text, @intCast(v.info), s.line);
            fs.freereg = @intCast(v.info);
        },
        .assign => |a| try assignStat(fs, a.targets, a.values, s.line),
        .assign_from => |a| try assignFrom(fs, a.targets, a.source, s.line),
        .function => |f| try functionStat(fs, f.path, f.method, f.func, s.line),
        .do_ => |b| try block(fs, b),
        .while_ => |w| try whileStat(fs, w.cond, w.body, s.line),
        .repeat_ => |r| try repeatStat(fs, r.body, r.cond, s.line),
        .if_ => |i| try ifStat(fs, i.clauses, i.else_, s.line),
        .numeric_for => |f| try numericFor(fs, f.name, f.start, f.limit, f.step, f.body, s.line),
        .generic_for => |f| if (f.from) try fromFor(fs, f.names, f.exprs, f.body, s.line) else try genericFor(fs, f.names, f.exprs, f.body, s.line),
        .return_ => |vals| try returnStat(fs, vals, s.line),
        .provide => |vals| try provideStat(fs, vals, s.line),
        .break_ => try newGoto(fs, "break", s.line, try jump(fs)),
        .continue_ => try continueStat(fs, s.line),
        .goto_ => |n| try gotoStat(fs, n.text, s.line),
        .label => |n| try labelStat(fs, n.text, s.line),
        .catch_ => |c| {
            const base = fs.freereg;
            const e = try fs.c.arena.create(ast.Expr);
            e.* = .{ .span = s.span, .line = s.line, .kind = .{ .catch_ = c } };
            try genCatch(fs, c, base, 0);
            fs.freereg = base;
        },
    }
    // Registers above the active locals are free after each statement.
    fs.freereg = nvarstack(fs);
}

fn attribKind(fs: *FuncState, an: ast.AttName, line: u32, allow_runtime: bool) Error!VarKind {
    var k: VarKind = .regular;
    for (an.attribs) |a| switch (a) {
        .@"const" => k = .const_,
        .close => k = .close,
        .group => k = .group,
        // A plain `local` statement and a group field handle these first,
        // so any other declaration rejects them.
        .meta => return fs.c.err(line, "cannot use <meta> in this declaration", .{}),
        .lazy => return fs.c.err(line, "cannot use <lazy> in this declaration", .{}),
        .runtime => if (!allow_runtime) return fs.c.err(line, "runtime attributes not supported in this context", .{}),
    };
    return k;
}

fn hasRuntimeAttribs(an: ast.AttName) bool {
    for (an.attribs) |a| if (a == .runtime) return true;
    return false;
}

fn adjustAssign(fs: *FuncState, nvars: u32, nexps: u32, e: *ExpDesc) Error!void {
    const needed: i32 = @as(i32, @intCast(nvars)) - @as(i32, @intCast(nexps));
    if (e.isMulti()) {
        // The multi-valued expression supplies `extra` values. After
        // setReturns it owns one register, like a call result slot.
        const extra = @max(needed + 1, 0);
        try setReturns(fs, e, extra);
        if (needed > 0) {
            try reserveRegs(fs, @intCast(needed));
        } else {
            fs.freereg = @intCast(@as(i32, fs.freereg) + needed);
        }
        return;
    }
    if (e.kind != .void_) try exp2nextreg(fs, e);
    if (needed > 0) {
        const reg = fs.freereg;
        try reserveRegs(fs, @intCast(needed));
        try loadNil(fs, reg, @intCast(needed));
    } else {
        fs.freereg = @intCast(@as(i32, fs.freereg) + needed);
    }
}

fn explist(fs: *FuncState, exprs: []*ast.Expr, last: *ExpDesc) Error!u32 {
    for (exprs, 0..) |e, i| {
        try expr(fs, e, last);
        if (i + 1 < exprs.len) try exp2nextreg(fs, last);
    }
    return @intCast(exprs.len);
}

fn localStat(fs: *FuncState, names: []ast.AttName, values: []*ast.Expr, line: u32) Error!void {
    for (names) |an| if (an.has(.meta)) return metaLocal(fs, names, values, line);
    for (names) |an| if (an.has(.lazy)) return lazyLocal(fs, names, values, line);
    var toclose: ?u32 = null;
    var has_runtime = false;
    for (names, 0..) |an, i| {
        const kind = try attribKind(fs, an, line, true);
        if (hasRuntimeAttribs(an)) {
            has_runtime = true;
            if (names.len > 1) return fs.c.err(line, "runtime attributes not supported with multiple variables", .{});
        }
        if (kind == .close) {
            if (toclose != null) return fs.c.err(line, "multiple to-be-closed variables in local list", .{});
            toclose = @intCast(i);
        }
    }
    // Runtime attribute handlers are evaluated before the initializer,
    // into hidden locals.
    var handler_regs: []u8 = &.{};
    if (has_runtime) handler_regs = try evalHandlers(fs, names[0], line);
    // Compile-time constant: single const local with constant initializer.
    // Debug builds keep it in a register so the debugger can show it.
    if (names.len == values.len and !has_runtime and !fs.c.opts.debug) {
        const lastn = names[names.len - 1];
        const k = try attribKind(fs, lastn, line, true);
        if (k == .const_) {
            var e: ExpDesc = .{};
            const saved_free = fs.freereg;
            const saved_pc = pc(fs);
            // Evaluate leading values first.
            var i: usize = 0;
            while (i + 1 < values.len) : (i += 1) {
                var le: ExpDesc = .{};
                try expr(fs, values[i], &le);
                try exp2nextreg(fs, &le);
            }
            try expr(fs, values[values.len - 1], &e);
            if (isCompileTimeConst(fs, &e)) {
                // Declare earlier names normally, the last as a constant.
                for (names[0 .. names.len - 1]) |an| _ = try newLocalVar(fs, an.name.text, try attribKind(fs, an, line, false));
                const vidx = try newLocalVar(fs, lastn.name.text, .ctc);
                getLocalVar(fs, vidx).k = e;
                try adjustLocalVars(fs, @intCast(names.len));
                return;
            }
            // Not a constant: finish as a normal declaration. The values
            // are placed first, because a deferred value such as a do
            // expression compiles a block of its own, and the names
            // declare only after it.
            try adjustAssign(fs, @intCast(names.len), @intCast(values.len), &e);
            for (names) |an| _ = try newLocalVar(fs, an.name.text, try attribKind(fs, an, line, true));
            try adjustLocalVars(fs, @intCast(names.len));
            _ = saved_free;
            _ = saved_pc;
            try checkToClose(fs, toclose, @intCast(names.len));
            return;
        }
    }
    var e: ExpDesc = .{};
    const nexps = if (values.len == 0) 0 else try explist(fs, values, &e);
    try adjustAssign(fs, @intCast(names.len), nexps, &e);
    for (names) |an| _ = try newLocalVar(fs, an.name.text, try attribKind(fs, an, line, true));
    if (has_runtime and values.len > 0) {
        try runHandlers(fs, handler_regs, names[0].name.text, fs.freereg - 1);
    }
    try adjustLocalVars(fs, @intCast(names.len));
    if (has_runtime) getLocalVar(fs, fs.nactvar - 1).handlers = handler_regs;
    try checkToClose(fs, toclose, @intCast(names.len));
}

fn isCompileTimeConst(fs: *FuncState, e: *ExpDesc) bool {
    _ = fs;
    if (e.hasJumps()) return false;
    return switch (e.kind) {
        .nil, .true_, .false_, .kint, .kflt, .kstr => true,
        else => false,
    };
}

/// Marks the `idx`-th of the `n` just declared locals as to-be-closed.
fn checkToClose(fs: *FuncState, toclose: ?u32, n: u32) Error!void {
    const idx = toclose orelse return;
    const bl = fs.bl.?;
    bl.upval = true;
    bl.inside_tbc = true;
    fs.needs_close = true;
    const v = getLocalVar(fs, fs.nactvar - n + idx);
    try codeABC(fs, .tbc, v.reg, 0, 0);
}

fn evalHandlers(fs: *FuncState, an: ast.AttName, line: u32) Error![]u8 {
    var regs: std.ArrayList(u8) = .empty;
    for (an.attribs) |a| {
        if (a != .runtime) continue;
        _ = try newLocalVar(fs, "(attr)", .regular);
        var e: ExpDesc = .{};
        try expr(fs, a.runtime, &e);
        try exp2nextreg(fs, &e);
        try adjustLocalVars(fs, 1);
        try regs.append(fs.c.arena, getLocalVar(fs, fs.nactvar - 1).reg);
    }
    _ = line;
    return regs.toOwnedSlice(fs.c.arena);
}

/// Emits handler calls for a value in register `vreg`: for each handler,
/// if the value is not nil, v = h(name, v) keeping v when h returns nil.
fn runHandlers(fs: *FuncState, handlers: []const u8, name: []const u8, vreg: u32) Error!void {
    if (handlers.len == 0) return;
    // if v == nil skip all
    const skip = try condJump(fs, .testnil, vreg, 0, 1);
    for (handlers) |h| {
        const base = fs.freereg;
        try reserveRegs(fs, 3);
        try codeABC(fs, .move, base, h, 0);
        _ = try emitABx(fs, .loadk, base + 1, try stringK(fs, name));
        try codeABC(fs, .move, base + 2, vreg, 0);
        try codeABC(fs, .call, base, 3, 2);
        // if result ~= nil then v = result
        const keep = try condJump(fs, .testnil, base, 0, 1);
        try codeABC(fs, .move, vreg, base, 0);
        try patchToHere(fs, keep);
        fs.freereg = base;
    }
    try patchToHere(fs, skip);
}

fn localFrom(fs: *FuncState, names: []ast.AttName, source: *ast.Expr, line: u32) Error!void {
    for (names) |an| {
        const k = try attribKind(fs, an, line, true);
        if (k == .close) return fs.c.err(line, "cannot use 'from' with to-be-closed variables", .{});
        if (hasRuntimeAttribs(an)) return fs.c.err(line, "runtime attributes not supported with 'from'", .{});
    }
    // Group source: copy field values.
    const base = fs.freereg;
    try reserveRegs(fs, @intCast(names.len));
    var src: ExpDesc = .{};
    if (try groupSourceFields(fs, source, names, base, line)) {
        // done
    } else {
        try expr(fs, source, &src);
        const sreg = try exp2anyreg(fs, &src);
        for (names, 0..) |an, i| try getFieldTo(fs, base + @as(u32, @intCast(i)), sreg, an.name.text);
    }
    fs.freereg = base + @as(u8, @intCast(names.len));
    for (names) |an| {
        const k = try attribKind(fs, an, line, false);
        _ = try newLocalVar(fs, an.name.text, if (k == .const_) .const_ else .regular);
    }
    try adjustLocalVars(fs, @intCast(names.len));
}

fn groupSourceFields(fs: *FuncState, source: *ast.Expr, names: []ast.AttName, base: u32, line: u32) Error!bool {
    if (source.kind != .name) return false;
    var rv: ExpDesc = .{};
    try singleVarAux(fs, source.kind.name.text, &rv, true);
    if (!(rv.kind == .void_ and rv.info == -3)) return false;
    const vd = fs.c.actvars.items[@intCast(rv.aux)];
    const group = vd.group.?;
    for (names, 0..) |an, i| {
        const m = group.fields.get(an.name.text) orelse return fs.c.err(line, "'{s}' is not a field of group '{s}'", .{ an.name.text, vd.name });
        switch (m) {
            .sub => return fs.c.err(line, "cannot deconstruct subgroup '{s}' with 'from'", .{an.name.text}),
            .field => |vabs| {
                var fv: ExpDesc = .{};
                try groupField(fs, vabs, &fv);
                try exp2reg(fs, &fv, base + @as(u32, @intCast(i)));
            },
        }
    }
    return true;
}

fn localGroup(fs: *FuncState, names: []ast.AttName, inits: []ast.GroupInit, line: u32) Error!void {
    for (names) |an| {
        const k = try attribKind(fs, an, line, true);
        if (k != .group) return fs.c.err(line, "cannot mix <group> with non-group variables", .{});
        if (an.has(.close)) return fs.c.err(line, "cannot use <close> with <group> variables", .{});
    }
    if (inits.len != names.len) return fs.c.err(line, "'=' expected", .{});
    for (names, inits) |an, init| {
        var handlers: []u8 = &.{};
        if (hasRuntimeAttribs(an)) handlers = try evalHandlers(fs, an, line);
        const group = try fs.c.arena.create(Group);
        group.* = .{};
        switch (init) {
            .ctor => |fields| try groupCtor(fs, group, fields, handlers, an.name.text, line),
            .copy => |src| try groupCopy(fs, group, src, line),
        }
        const vidx = try newLocalVar(fs, an.name.text, .group);
        getLocalVar(fs, vidx).group = group;
        try adjustLocalVars(fs, 1);
    }
}

fn groupCtor(fs: *FuncState, group: *Group, fields: []ast.GroupField, handlers: []const u8, prefix_name: []const u8, line: u32) Error!void {
    for (fields) |gf| {
        const k: VarKind = if (gf.name.has(.lazy)) .regular else try attribKind(fs, gf.name, line, false);
        switch (gf.value) {
            .group => |sub| {
                const sg = try fs.c.arena.create(Group);
                sg.* = .{};
                try groupCtor(fs, sg, sub, &.{}, gf.name.name.text, line);
                try group.fields.put(fs.c.arena, gf.name.name.text, .{ .sub = sg });
            },
            .expr => |e| {
                // Field locals have hidden names so plain lookups never
                // find them.
                const hidden = try std.fmt.allocPrint(fs.c.arena, "({s}.{s})", .{ prefix_name, gf.name.name.text });
                if (gf.name.has(.lazy)) {
                    // A lazy field is a lazy local under the hidden name.
                    if (handlers.len > 0) return fs.c.err(line, "cannot combine <lazy> fields with runtime attributes of the group", .{});
                    var lazy_names = [_]ast.AttName{.{ .name = .{ .text = hidden, .span = gf.name.name.span }, .attribs = gf.name.attribs }};
                    var lazy_values = [_]*ast.Expr{e};
                    try lazyLocal(fs, &lazy_names, &lazy_values, line);
                    try group.fields.put(fs.c.arena, gf.name.name.text, .{ .field = fs.first_local + fs.nactvar - 1 });
                    continue;
                }
                var ve: ExpDesc = .{};
                try expr(fs, e, &ve);
                try exp2nextreg(fs, &ve);
                if (handlers.len > 0) {
                    const fname = try std.fmt.allocPrint(fs.c.arena, "{s}.{s}", .{ prefix_name, gf.name.name.text });
                    try runHandlers(fs, handlers, fname, @intCast(ve.info));
                }
                const vidx = try newLocalVar(fs, hidden, if (k == .const_ or k == .close) .const_ else .regular);
                try adjustLocalVars(fs, 1);
                if (handlers.len > 0) getLocalVar(fs, vidx).handlers = @constCast(handlers);
                try group.fields.put(fs.c.arena, gf.name.name.text, .{ .field = fs.first_local + vidx });
            },
        }
    }
}

fn groupCopy(fs: *FuncState, group: *Group, src: ast.Name, line: u32) Error!void {
    var rv: ExpDesc = .{};
    try singleVarAux(fs, src.text, &rv, true);
    if (!(rv.kind == .void_ and rv.info == -3)) return fs.c.err(line, "group can only be copied from another group", .{});
    const sg = fs.c.actvars.items[@intCast(rv.aux)].group.?;
    var it = sg.fields.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .sub => |sub| try group.fields.put(fs.c.arena, entry.key_ptr.*, .{ .sub = sub }),
            .field => |vabs| {
                const svd = fs.c.actvars.items[vabs];
                const reg = fs.freereg;
                var fv: ExpDesc = .{};
                try groupField(fs, vabs, &fv);
                try reserveRegs(fs, 1);
                try exp2reg(fs, &fv, reg);
                const vidx = try newLocalVar(fs, svd.name, if (svd.kind == .lazy) .const_ else svd.kind);
                try adjustLocalVars(fs, 1);
                try group.fields.put(fs.c.arena, entry.key_ptr.*, .{ .field = fs.first_local + vidx });
            },
        }
    }
}

// --- globals ----------------------------------------------------------

fn globalKind(fs: *FuncState, attribs: []const ast.Attrib, line: u32) Error!bool {
    var readonly = false;
    for (attribs) |a| switch (a) {
        .@"const" => readonly = true,
        .close => return fs.c.err(line, "global variables cannot be to-be-closed", .{}),
        .group => return fs.c.err(line, "global variables cannot be groups", .{}),
        .meta => return fs.c.err(line, "global variables cannot be <meta>", .{}),
        .lazy => return fs.c.err(line, "global variables cannot be <lazy>", .{}),
        .runtime => return fs.c.err(line, "runtime attributes not supported in this context", .{}),
    };
    return readonly;
}

fn declareGlobals(fs: *FuncState, defaults: []const ast.Attrib, names: []const ast.AttName, line: u32) Error!void {
    const def_ro = try globalKind(fs, defaults, line);
    for (names) |an| {
        if (std.mem.eql(u8, an.name.text, "flags")) return fs.c.err(line, "cannot declare 'flags' (reserved name)", .{});
        const ro = def_ro or try globalKind(fs, an.attribs, line);
        const vidx = try newLocalVar(fs, an.name.text, .global_named);
        getLocalVar(fs, vidx).readonly = ro;
    }
    try adjustLocalVars(fs, @intCast(names.len));
}

fn globalStat(fs: *FuncState, defaults: []ast.Attrib, names: []ast.AttName, values: ?[]*ast.Expr, star: bool, line: u32) Error!void {
    if (star) {
        const ro = try globalKind(fs, defaults, line);
        const vidx = try newLocalVar(fs, "*", .global_star);
        getLocalVar(fs, vidx).readonly = ro;
        try adjustLocalVars(fs, 1);
        return;
    }
    if (values) |vals| {
        // Evaluate first, then declare and define from last to first.
        const base = fs.freereg;
        var e: ExpDesc = .{};
        const n = try explist(fs, vals, &e);
        try adjustAssign(fs, @intCast(names.len), n, &e);
        try declareGlobals(fs, defaults, names, line);
        var i = names.len;
        while (i > 0) {
            i -= 1;
            try globalDefine(fs, names[i].name.text, base + @as(u32, @intCast(i)), line);
        }
        fs.freereg = base;
        return;
    }
    try declareGlobals(fs, defaults, names, line);
}

fn globalFrom(fs: *FuncState, defaults: []ast.Attrib, names: []ast.AttName, source: *ast.Expr, line: u32) Error!void {
    const base = fs.freereg;
    try reserveRegs(fs, @intCast(names.len));
    var src: ExpDesc = .{};
    try expr(fs, source, &src);
    const sreg = try exp2anyreg(fs, &src);
    for (names, 0..) |an, i| try getFieldTo(fs, base + @as(u32, @intCast(i)), sreg, an.name.text);
    fs.freereg = base + @as(u8, @intCast(names.len));
    try declareGlobals(fs, defaults, names, line);
    var i = names.len;
    while (i > 0) {
        i -= 1;
        try globalDefine(fs, names[i].name.text, base + @as(u32, @intCast(i)), line);
    }
    fs.freereg = base;
}

/// Stores R[reg] into global `name`, raising if it is already defined.
fn globalDefine(fs: *FuncState, name: []const u8, reg: u32, line: u32) Error!void {
    var env: ExpDesc = .{};
    try singleVarAux(fs, fs.c.env_name, &env, true);
    const ki = try stringK(fs, name);
    if (ki > 255) return fs.c.err(line, "too many constants", .{});
    if (env.kind == .upval) {
        try codeABC(fs, .globaldef, @intCast(env.info), ki, reg);
    } else {
        const er = try exp2anyreg(fs, &env);
        try codeABC(fs, .globaldefr, er, ki, reg);
        freeExp(fs, &env);
    }
}

// --- assignment -------------------------------------------------------

fn targetName(e: *ast.Expr) []const u8 {
    return switch (e.kind) {
        .name => |n| n.text,
        .index => |ix| if (ix.dot) ix.key.kind.string else "?",
        else => "?",
    };
}

fn assignStat(fs: *FuncState, targets: []*ast.Expr, values: []*ast.Expr, line: u32) Error!void {
    // Group overwrite: `g = { f = v, ... }`.
    if (targets.len == 1 and targets[0].kind == .name) {
        var rv: ExpDesc = .{};
        try singleVarAux(fs, targets[0].kind.name.text, &rv, true);
        if (rv.kind == .void_ and rv.info == -3) return groupOverwrite(fs, targets[0], values, line);
    }
    // Evaluate target prefixes (table and key registers) left to right,
    // then values, then store right to left.
    var descs = try fs.c.arena.alloc(ExpDesc, targets.len);
    for (targets, 0..) |t, i| {
        var v: ExpDesc = .{};
        try expr(fs, t, &v);
        switch (v.kind) {
            .local, .upval, .indexed, .indexup, .indexint, .indexstr, .ctc => {},
            else => return fs.c.err(line, "syntax error", .{}),
        }
        try checkReadonly(fs, &v, targetName(t), line);
        descs[i] = v;
    }
    try checkConflicts(fs, descs);
    var e: ExpDesc = .{};
    const nexps = try explist(fs, values, &e);
    if (nexps != targets.len or e.isMulti()) {
        try adjustAssign(fs, @intCast(targets.len), nexps, &e);
    } else {
        // Single exact match: store the last value directly.
        try setOneRet(fs, &e);
        const last = targets.len - 1;
        try storeTarget(fs, &descs[last], &e, targets[last]);
        var i = last;
        while (i > 0) {
            i -= 1;
            var ve = ExpDesc.init(.nonreloc, fs.freereg - 1);
            try storeTarget(fs, &descs[i], &ve, targets[i]);
        }
        return;
    }
    var i = targets.len;
    while (i > 0) {
        i -= 1;
        var ve = ExpDesc.init(.nonreloc, fs.freereg - 1);
        try storeTarget(fs, &descs[i], &ve, targets[i]);
    }
}

fn storeTarget(fs: *FuncState, v: *ExpDesc, ex: *ExpDesc, target: *ast.Expr) Error!void {
    // Runtime attribute handlers on local targets.
    if (v.kind == .local) {
        const vd = getLocalVar(fs, @intCast(v.aux));
        if (vd.handlers.len > 0) {
            try exp2nextreg(fs, ex);
            try runHandlers(fs, vd.handlers, publicName(vd.name), @intCast(ex.info));
        }
    }
    try storeVar(fs, v, ex);
    _ = target;
}

fn publicName(hidden: []const u8) []const u8 {
    if (hidden.len > 2 and hidden[0] == '(' and hidden[hidden.len - 1] == ')') return hidden[1 .. hidden.len - 1];
    return hidden;
}

/// The name a user wrote for a variable: a group field "(g.f)" is "f".
fn fieldName(hidden: []const u8) []const u8 {
    const p = publicName(hidden);
    if (p.len != hidden.len) if (std.mem.lastIndexOfScalar(u8, p, '.')) |dot| return p[dot + 1 ..];
    return p;
}

/// Multiple assignment stores right to left, so a local target is written
/// before the targets to its left. When one of those uses the local as its
/// table or key, copy the local first and index through the copy.
fn checkConflicts(fs: *FuncState, descs: []ExpDesc) Error!void {
    for (descs, 0..) |*d, i| {
        if (d.kind == .upval) {
            // An upvalue target conflicts with earlier fields of that same
            // upvalue table: load the table into a register for them.
            var conflict = false;
            for (descs[0..i]) |*o| {
                if (o.kind == .indexup and o.info == d.info) {
                    conflict = true;
                    o.* = .{ .kind = .indexstr, .info = fs.freereg, .aux = o.aux };
                }
            }
            if (conflict) {
                try codeABC(fs, .getupval, fs.freereg, @intCast(d.info), 0);
                try reserveRegs(fs, 1);
            }
            continue;
        }
        if (d.kind != .local) continue;
        const reg = d.info;
        var conflict = false;
        for (descs[0..i]) |*o| {
            switch (o.kind) {
                .indexed => {
                    if (o.info == reg) {
                        conflict = true;
                        o.info = fs.freereg;
                    }
                    if (o.aux == reg) {
                        conflict = true;
                        o.aux = fs.freereg;
                    }
                },
                .indexstr, .indexint => if (o.info == reg) {
                    conflict = true;
                    o.info = fs.freereg;
                },
                else => {},
            }
        }
        if (conflict) {
            try codeABC(fs, .move, fs.freereg, @intCast(reg), 0);
            try reserveRegs(fs, 1);
        }
    }
}

fn groupOverwrite(fs: *FuncState, target: *ast.Expr, values: []*ast.Expr, line: u32) Error!void {
    const gname = target.kind.name.text;
    var rv: ExpDesc = .{};
    try singleVarAux(fs, gname, &rv, true);
    const group = fs.c.actvars.items[@intCast(rv.aux)].group.?;
    if (values.len == 1 and values[0].kind == .name) {
        if (try groupSource(fs, values[0].kind.name.text)) |src| return groupAssign(fs, group, gname, src, line);
    }
    if (values.len != 1 or values[0].kind != .table) return fs.c.err(line, "group can only be assigned a constructor or another group", .{});
    for (values[0].kind.table) |f| {
        const nf = switch (f.kind) {
            .named => |n| n,
            else => return fs.c.err(line, "<name> expected", .{}),
        };
        const m = group.fields.get(nf.name.text) orelse return fs.c.err(line, "'{s}' is not a field of group '{s}'", .{ nf.name.text, gname });
        switch (m) {
            .sub => return fs.c.err(line, "cannot overwrite subgroups", .{}),
            .field => |vabs| {
                const vd = fs.c.actvars.items[vabs];
                if (vd.readonly) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{nf.name.text});
                var fv: ExpDesc = .{};
                try groupField(fs, vabs, &fv);
                var ve: ExpDesc = .{};
                try expr(fs, nf.value, &ve);
                try storeVar(fs, &fv, &ve);
            },
        }
    }
}

/// The group that `name` refers to, or null when it names something else.
fn groupSource(fs: *FuncState, name: []const u8) Error!?*Group {
    var rv: ExpDesc = .{};
    try singleVarAux(fs, name, &rv, true);
    if (!(rv.kind == .void_ and rv.info == -3)) return null;
    return fs.c.actvars.items[@intCast(rv.aux)].group.?;
}

/// `g = src` with another group: every field of `src` is assigned to the
/// field of `g` with the same name, as the constructor that lists them
/// would assign it.
fn groupAssign(fs: *FuncState, group: *Group, gname: []const u8, src: *Group, line: u32) Error!void {
    var it = src.fields.iterator();
    while (it.next()) |entry| {
        const svabs = switch (entry.value_ptr.*) {
            .sub => return fs.c.err(line, "cannot overwrite subgroups", .{}),
            .field => |v| v,
        };
        const m = group.fields.get(entry.key_ptr.*) orelse return fs.c.err(line, "'{s}' is not a field of group '{s}'", .{ entry.key_ptr.*, gname });
        switch (m) {
            .sub => return fs.c.err(line, "cannot overwrite subgroups", .{}),
            .field => |vabs| {
                if (fs.c.actvars.items[vabs].readonly) return fs.c.err(line, "attempt to assign to const variable '{s}'", .{entry.key_ptr.*});
                if (vabs == svabs) continue;
                var fv: ExpDesc = .{};
                try groupField(fs, vabs, &fv);
                var ve: ExpDesc = .{};
                try groupField(fs, svabs, &ve);
                try storeVar(fs, &fv, &ve);
            },
        }
    }
}

fn assignFrom(fs: *FuncState, targets: []*ast.Expr, source: *ast.Expr, line: u32) Error!void {
    var descs = try fs.c.arena.alloc(ExpDesc, targets.len);
    for (targets, 0..) |t, i| {
        var v: ExpDesc = .{};
        switch (t.kind) {
            .name => {},
            .index => {
                // Group field paths are simple variables.
                if (!try groupPath(fs, t, &v)) return fs.c.err(line, "'from' requires simple variable names", .{});
                try checkReadonly(fs, &v, targetName(t), line);
                descs[i] = v;
                continue;
            },
            else => return fs.c.err(line, "'from' requires simple variable names", .{}),
        }
        try expr(fs, t, &v);
        switch (v.kind) {
            .local, .upval, .indexup => {},
            .indexstr => return fs.c.err(line, "'from' requires simple variable names", .{}),
            else => return fs.c.err(line, "'from' requires simple variable names", .{}),
        }
        try checkReadonly(fs, &v, targetName(t), line);
        descs[i] = v;
    }
    const base = fs.freereg;
    try reserveRegs(fs, @intCast(targets.len));
    var src: ExpDesc = .{};
    const names = try fs.c.arena.alloc(ast.AttName, targets.len);
    for (targets, 0..) |t, i| names[i] = .{ .name = .{ .text = targetName(t), .span = t.span } };
    if (!try groupSourceFields(fs, source, names, base, line)) {
        try expr(fs, source, &src);
        const sreg = try exp2anyreg(fs, &src);
        for (names, 0..) |n, i| try getFieldTo(fs, base + @as(u32, @intCast(i)), sreg, n.name.text);
    }
    fs.freereg = base + @as(u8, @intCast(targets.len));
    var i = targets.len;
    while (i > 0) {
        i -= 1;
        var ve = ExpDesc.init(.nonreloc, base + @as(i32, @intCast(i)));
        try storeTarget(fs, &descs[i], &ve, targets[i]);
    }
    fs.freereg = base;
}

fn functionStat(fs: *FuncState, path: []ast.Name, method: ?ast.Name, f: *ast.Function, line: u32) Error!void {
    var v: ExpDesc = .{};
    try singleVar(fs, path[0].text, line, &v);
    if (path.len == 1 and method == null) try checkReadonly(fs, &v, path[0].text, line);
    for (path[1..]) |n| {
        try exp2anyregup(fs, &v);
        var k: ExpDesc = .{ .kind = .kstr, .strval = n.text };
        try indexed(fs, &v, &k);
    }
    if (method) |m| {
        try exp2anyregup(fs, &v);
        var k: ExpDesc = .{ .kind = .kstr, .strval = m.text };
        try indexed(fs, &v, &k);
    }
    var b: ExpDesc = .{};
    try funcExpr(fs, f, &b);
    try storeVar(fs, &v, &b);
}

// --- control flow -----------------------------------------------------

/// Generates a condition. Returns the false-exit jump list. Assignment
/// conditions declare their locals in the current block.
fn condition(fs: *FuncState, cond: ast.Cond, line: u32) Error!i32 {
    switch (cond) {
        .expr => |e| {
            var v: ExpDesc = .{};
            try expr(fs, e, &v);
            if (v.kind == .nil) v.kind = .false_;
            try goIfTrue(fs, &v);
            return v.f;
        },
        .assign => |a| {
            var toclose: ?u32 = null;
            for (a.names, 0..) |an, i| {
                const k = try attribKind(fs, an, line, false);
                if (k == .close) {
                    if (toclose != null) return fs.c.err(line, "multiple to-be-closed variables in condition", .{});
                    toclose = @intCast(i);
                }
                if (k == .group) return fs.c.err(line, "cannot mix <group> with non-group variables in condition", .{});
            }
            const first = fs.nactvar;
            const base = fs.freereg;
            var e: ExpDesc = .{};
            const n = try explist(fs, a.values, &e);
            try adjustAssign(fs, @intCast(a.names.len), n, &e);
            for (a.names) |an| _ = try newLocalVar(fs, an.name.text, try attribKind(fs, an, line, false));
            try adjustLocalVars(fs, @intCast(a.names.len));
            if (toclose) |tc| try codeABC(fs, .tbc, base + tc, 0, 0);
            if (toclose != null) {
                fs.bl.?.upval = true;
                fs.bl.?.inside_tbc = true;
            }
            return condTests(fs, first, @intCast(a.names.len));
        },
        .from => |f| {
            for (f.names) |an| {
                const k = try attribKind(fs, an, line, false);
                if (k == .group) return fs.c.err(line, "cannot use 'from' with <group> variables", .{});
                if (k == .close) return fs.c.err(line, "cannot use 'from' with to-be-closed variables", .{});
            }
            const first = fs.nactvar;
            try localFrom(fs, f.names, f.source, line);
            return condTests(fs, first, @intCast(f.names.len));
        },
        .group => |g| {
            try localGroup(fs, g.names, g.inits, line);
            return no_jump; // group conditions are always true
        },
    }
}

/// Jumps out (false list) when any of the `n` locals starting at `first`
/// is falsy.
fn condTests(fs: *FuncState, first: u32, n: u32) Error!i32 {
    var f: i32 = no_jump;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const vd = getLocalVar(fs, first + i);
        const j = try condJump(fs, .test_, vd.reg, 0, 0);
        try concatJumps(fs, &f, j);
    }
    return f;
}

/// The value of `flags.NAME` when `obj` is the reserved name `flags`, no
/// local hides it, and `key` is a string constant.
fn foldFlagRead(fs: *FuncState, obj: *const ast.Expr, key: *const ast.Expr) ?Value {
    const flags = fs.c.opts.flags orelse return Value.nil;
    if (obj.kind != .name or !std.mem.eql(u8, obj.kind.name.text, "flags")) return null;
    if (key.kind != .string) return null;
    if (!flagsIsReserved(fs)) return null;
    return flags.get(key.kind.string) orelse Value.nil;
}

/// Whether the name `flags` refers to the reserved global here.
fn flagsIsReserved(fs: *FuncState) bool {
    var gi: i32 = -1;
    if (searchVar(fs, "flags", &gi)) |vidx| {
        const vd = getLocalVar(fs, vidx);
        if (vd.kind != .global_star and vd.kind != .global_named) return false;
    }
    var p = fs.parent;
    while (p) |pf| : (p = pf.parent) {
        var pp: i32 = -1;
        if (searchVar(pf, "flags", &pp)) |vidx| {
            const vd = getLocalVar(pf, vidx);
            if (vd.kind != .global_star and vd.kind != .global_named) return false;
        }
    }
    return true;
}

/// The truth of an `if` condition known at compile time, or null
/// (`spec/design/meta.md`, section 4). Literals, flag reads, comparisons
/// and `and`, `or`, `not` fold here directly. A condition that also
/// reads `<meta>` and `<const>` values, computes, or calls a pure library
/// function is evaluated in the meta state. Folding never hides a run-time
/// effect: a condition that raises stays, and `and` and `or` fold only
/// when the left operand decides the result or both operands fold.
fn foldCondition(fs: *FuncState, cond: ast.Cond, line: u32) Error!?bool {
    const e = switch (cond) {
        .expr => |x| x,
        else => return null,
    };
    return foldKnown(fs, e, line);
}

fn foldKnown(fs: *FuncState, e: *ast.Expr, line: u32) Error!?bool {
    switch (e.kind) {
        .paren => |inner| return foldKnown(fs, inner, line),
        .unop => |u| if (u.op == .not) {
            const r = try foldKnown(fs, u.operand, line) orelse return null;
            return !r;
        },
        .binop => |b| if (b.op == .@"and" or b.op == .@"or") {
            const l = try foldKnown(fs, b.lhs, line) orelse return null;
            const decides = if (b.op == .@"and") !l else l;
            if (decides) return l;
            return foldKnown(fs, b.rhs, line);
        },
        else => {},
    }
    if (foldFlagCond(fs, e)) |r| return r.value;
    if (fs.c.discarding > 0 or !fs.c.opts.meta_eval) return null;
    if (!isKnown(fs, e)) return null;
    return switch (try metaEval(fs, e, line)) {
        .ok => |v| v.truthy(),
        .err => null,
    };
}

const FoldedCond = struct { value: bool, flag: bool };

fn foldFlagCond(fs: *FuncState, e: *const ast.Expr) ?FoldedCond {
    switch (e.kind) {
        .paren => |inner| return foldFlagCond(fs, inner),
        .unop => |u| {
            if (u.op != .not) return null;
            const r = foldFlagCond(fs, u.operand) orelse return null;
            return .{ .value = !r.value, .flag = r.flag };
        },
        .binop => |b| switch (b.op) {
            .@"and", .@"or" => {
                const l = foldFlagCond(fs, b.lhs) orelse return null;
                const decides = if (b.op == .@"and") !l.value else l.value;
                if (decides) return l;
                const r = foldFlagCond(fs, b.rhs) orelse return null;
                return .{ .value = r.value, .flag = l.flag or r.flag };
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const l = foldOperand(fs, b.lhs) orelse return null;
                const r = foldOperand(fs, b.rhs) orelse return null;
                const v = foldCompare(b.op, l.value, r.value) orelse return null;
                return .{ .value = v, .flag = l.flag or r.flag };
            },
            else => return null,
        },
        .index => {
            const v = flagValue(fs, e) orelse return null;
            return .{ .value = v.truthy(), .flag = true };
        },
        .true => return .{ .value = true, .flag = false },
        .false, .nil => return .{ .value = false, .flag = false },
        .name => {
            const o = foldOperand(fs, e) orelse return null;
            return .{ .value = switch (o.value) {
                .nil => false,
                .boolean => |b| b,
                else => true,
            }, .flag = false };
        },
        else => return null,
    }
}

/// A literal operand of a folded comparison: nil, a boolean, a number,
/// or a string. String values are borrowed from the syntax tree or from
/// the flags table, which both outlive the compilation.
const FoldLit = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    str: []const u8,
};

const FoldedOperand = struct { value: FoldLit, flag: bool };

fn foldOperand(fs: *FuncState, e: *const ast.Expr) ?FoldedOperand {
    switch (e.kind) {
        .paren => |inner| return foldOperand(fs, inner),
        .nil => return .{ .value = .nil, .flag = false },
        .true => return .{ .value = .{ .boolean = true }, .flag = false },
        .false => return .{ .value = .{ .boolean = false }, .flag = false },
        .integer => |i| return .{ .value = .{ .int = i }, .flag = false },
        .float => |f| return .{ .value = .{ .float = f }, .flag = false },
        .string => |s| return .{ .value = .{ .str = s }, .flag = false },
        .unop => |u| {
            if (u.op != .neg) return null;
            switch (u.operand.kind) {
                .integer => |i| return .{ .value = .{ .int = 0 -% i }, .flag = false },
                .float => |f| return .{ .value = .{ .float = -f }, .flag = false },
                else => return null,
            }
        },
        .name => |n| {
            const vd = knownLocal(fs, n.text) orelse return null;
            if (vd.kind != .ctc) return null;
            const k = vd.k;
            const lit: FoldLit = switch (k.kind) {
                .nil => .nil,
                .true_ => .{ .boolean = true },
                .false_ => .{ .boolean = false },
                .kint => .{ .int = k.ival },
                .kflt => .{ .float = k.nval },
                .kstr => .{ .str = k.strval },
                else => return null,
            };
            return .{ .value = lit, .flag = false };
        },
        .index => {
            const v = flagValue(fs, e) orelse return null;
            const lit: FoldLit = switch (v.tag) {
                .nil => .nil,
                .true => .{ .boolean = true },
                .false => .{ .boolean = false },
                .integer => .{ .int = v.asInt() },
                .float => .{ .float = v.asFloat() },
                .string => .{ .str = v.as(vm.object.String).bytes() },
                else => return null,
            };
            return .{ .value = lit, .flag = true };
        },
        else => return null,
    }
}

/// The value of `e` when it is `flags.NAME` or `flags["NAME"]`. The
/// caller has checked that `flags` is the reserved name.
fn flagValue(fs: *FuncState, e: *const ast.Expr) ?Value {
    const flags = fs.c.opts.flags orelse return null;
    if (!flagsIsReserved(fs)) return null;
    if (e.kind != .index) return null;
    const ix = e.kind.index;
    if (ix.obj.kind != .name or !std.mem.eql(u8, ix.obj.kind.name.text, "flags")) return null;
    if (ix.key.kind != .string) return null;
    return flags.get(ix.key.kind.string) orelse Value.nil;
}

/// The result of comparing two literals as the interpreter would, or
/// null when the comparison raises an error at run time.
fn foldCompare(op: ast.BinOp, a: FoldLit, b: FoldLit) ?bool {
    switch (op) {
        .eq => return foldEqual(a, b),
        .ne => return !foldEqual(a, b),
        .lt => return foldLess(a, b, false),
        .le => return foldLess(a, b, true),
        .gt => return foldLess(b, a, false),
        .ge => return foldLess(b, a, true),
        else => return null,
    }
}

fn foldEqual(a: FoldLit, b: FoldLit) bool {
    return switch (a) {
        .nil => b == .nil,
        .boolean => |x| b == .boolean and b.boolean == x,
        .str => |x| b == .str and std.mem.eql(u8, x, b.str),
        .int => |x| switch (b) {
            .int => |y| x == y,
            .float => |y| vm.ops.floatToInt(y) == x,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .int => |y| vm.ops.floatToInt(x) == y,
            else => false,
        },
    };
}

fn foldLess(a: FoldLit, b: FoldLit, or_equal: bool) ?bool {
    switch (a) {
        .str => |x| {
            if (b != .str) return null;
            const o = std.mem.order(u8, x, b.str);
            return if (or_equal) o != .gt else o == .lt;
        },
        .int, .float => {
            const av = foldNumber(a);
            const bv = switch (b) {
                .int, .float => foldNumber(b),
                else => return null,
            };
            if (a == .int and b == .int) return if (or_equal) a.int <= b.int else a.int < b.int;
            if (a == .float and b == .float) return if (or_equal) a.float <= b.float else a.float < b.float;
            return vm.ops.intFloatLess(av, bv, or_equal);
        },
        else => return null,
    }
}

fn foldNumber(x: FoldLit) Value {
    return switch (x) {
        .int => |i| Value.int(i),
        .float => |f| Value.float(f),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------
// Compile-time evaluation (`spec/design/meta.md`)

/// The innermost declaration of `name` visible here, or null when the
/// name is a global. Locals of enclosing functions count, since a nested
/// function reaches them as upvalues.
fn knownLocal(fs: *FuncState, name: []const u8) ?*VarDesc {
    const vars = fs.c.actvars.items;
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        const vd = &vars[i];
        if (!std.mem.eql(u8, vd.name, name)) continue;
        if (vd.kind == .global_named or vd.kind == .global_star) return null;
        return vd;
    }
    return null;
}

fn isGlobalName(fs: *FuncState, name: []const u8) bool {
    return knownLocal(fs, name) == null;
}

/// Functions of the standard library that compute from their arguments
/// alone, with no side effect and no dependence on the locale. A call of
/// one with arguments known at compile time folds.
const pure_string = [_][]const u8{ "byte", "char", "find", "format", "gsub", "join", "len", "lower", "ltrim", "match", "rep", "reverse", "rtrim", "split", "sub", "trim", "upper" };
const pure_math = [_][]const u8{ "abs", "acos", "asin", "atan", "ceil", "cos", "deg", "exp", "floor", "fmod", "frexp", "ldexp", "log", "max", "min", "modf", "rad", "sin", "sqrt", "tan", "tointeger", "type", "ult" };
const pure_utf8 = [_][]const u8{ "char", "codepoint", "len", "offset" };
const pure_base = [_][]const u8{ "tonumber", "tostring", "type" };
/// Constant fields of the standard library.
const known_math = [_][]const u8{ "huge", "maxinteger", "mininteger", "pi" };
const known_utf8 = [_][]const u8{"charpattern"};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// Whether `e` names a pure library function: `string.find`,
/// `math.floor`, `utf8.len`, or `tostring`, with the library a global.
fn isPureFunction(fs: *FuncState, e: *const ast.Expr) bool {
    switch (e.kind) {
        .name => |n| return inList(&pure_base, n.text) and isGlobalName(fs, n.text),
        .index => |ix| {
            if (ix.obj.kind != .name or ix.key.kind != .string) return false;
            const lib = ix.obj.kind.name.text;
            const f = ix.key.kind.string;
            if (!isGlobalName(fs, lib)) return false;
            if (std.mem.eql(u8, lib, "string")) return inList(&pure_string, f);
            if (std.mem.eql(u8, lib, "math")) return inList(&pure_math, f);
            if (std.mem.eql(u8, lib, "utf8")) return inList(&pure_utf8, f);
            return false;
        },
        else => return false,
    }
}

/// Whether the value of `e` is known at compile time: it is built from
/// literals, flag reads, `<meta>` locals, `<const>` compile-time
/// constants, fields of these, operators, and calls of pure library
/// functions with known arguments.
fn isKnown(fs: *FuncState, e: *const ast.Expr) bool {
    switch (e.kind) {
        .nil, .true, .false, .integer, .float, .string, .bigint, .decimal => return true,
        .paren => |inner| return isKnown(fs, inner),
        .unop => |u| return isKnown(fs, u.operand),
        .binop => |b| return isKnown(fs, b.lhs) and isKnown(fs, b.rhs),
        .name => |n| {
            const vd = knownLocal(fs, n.text) orelse return false;
            return vd.kind == .ctc or vd.meta_value != null;
        },
        .index => |ix| {
            if (!isKnown(fs, ix.key)) return false;
            if (ix.obj.kind == .name) {
                const name = ix.obj.kind.name.text;
                if (isGlobalName(fs, name)) {
                    if (std.mem.eql(u8, name, "flags")) return fs.c.opts.flags != null and flagsIsReserved(fs);
                    if (ix.key.kind != .string) return false;
                    if (std.mem.eql(u8, name, "math")) return inList(&known_math, ix.key.kind.string);
                    if (std.mem.eql(u8, name, "utf8")) return inList(&known_utf8, ix.key.kind.string);
                    return false;
                }
            }
            return isKnown(fs, ix.obj);
        },
        .call => |c| {
            if (!isPureFunction(fs, c.callee)) return false;
            for (c.args) |a| if (!isKnown(fs, a)) return false;
            return true;
        },
        .method => |m| {
            if (!inList(&pure_string, m.name.text)) return false;
            if (!isKnown(fs, m.obj)) return false;
            for (m.args) |a| if (!isKnown(fs, a)) return false;
            return true;
        },
        else => return false,
    }
}

/// The meta state of the chunk, created on first use.
fn metaState(fs: *FuncState, line: u32) Error!*meta.Meta {
    const c = fs.c;
    if (c.meta) |m| return m;
    c.meta = meta.open(c.g, c.opts.flags, c.opts.meta_grants) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MetaSetup => return c.err(line, "meta: cannot create the compile-time state", .{}),
    };
    return c.meta.?;
}

/// Evaluates `e` at compile time with every visible `<meta>` local and
/// `<const>` compile-time constant bound by name.
fn metaEval(fs: *FuncState, e: *ast.Expr, line: u32) Error!meta.EvalResult {
    const c = fs.c;
    const m = try metaState(fs, line);
    var known: std.ArrayList(meta.Known) = .empty;
    var unknown: std.StringHashMapUnmanaged(void) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const vars = c.actvars.items;
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        const vd = &vars[i];
        if (vd.name.len == 0 or vd.name[0] == '(') continue;
        if ((try seen.getOrPut(c.arena, vd.name)).found_existing) continue;
        switch (vd.kind) {
            .global_named, .global_star => {},
            .ctc => try known.append(c.arena, .{ .name = vd.name, .value = vd.meta_value orelse try meta.intoMeta(m, try ctcValue(fs, vd.k)) }),
            else => if (vd.meta_value) |mv| {
                try known.append(c.arena, .{ .name = vd.name, .value = mv });
            } else try unknown.put(c.arena, vd.name, {}),
        }
    }
    return meta.eval(m, c.arena, c.opts.chunkname, e, known.items, &unknown);
}

/// The value of a compile-time constant descriptor, in the target state.
fn ctcValue(fs: *FuncState, k: ExpDesc) Error!Value {
    return switch (k.kind) {
        .nil => .nil,
        .true_ => .true,
        .false_ => .false,
        .kint => Value.int(k.ival),
        .kflt => Value.float(k.nval),
        .kstr => Value.obj(.string, try fs.c.newString(k.strval)),
        else => .nil,
    };
}

/// A compile error for an error raised at compile time. A message that
/// starts with a position in this chunk keeps that position, which is the
/// failing line of the initializer.
fn metaError(c: *Compiler, line: u32, msg: []const u8) Error {
    // A compile error of the initializer names the chunk as the compiler
    // does, and an error raised while it runs names it as the runtime does.
    for ([_][]const u8{ @import("../syntax/parser.zig").chunkDisplay(c.arena, c.opts.chunkname), vm.state.chunkId(c.opts.chunkname) }) |name| {
        if (!std.mem.startsWith(u8, msg, name) or msg.len <= name.len or msg[name.len] != ':') continue;
        const rest = msg[name.len + 1 ..];
        if (std.mem.indexOf(u8, rest, ": ")) |colon| {
            if (std.fmt.parseInt(u32, rest[0..colon], 10)) |at| {
                return c.err(at, "meta: {s}", .{rest[colon + 2 ..]});
            } else |_| {}
        }
    }
    return c.err(line, "meta: {s}", .{msg});
}

/// `local name <meta> = exp`: evaluates `exp` at compile time and declares
/// `name` with the value as a constant.
fn metaLocal(fs: *FuncState, names: []ast.AttName, values: []*ast.Expr, line: u32) Error!void {
    const c = fs.c;
    if (names.len != 1) return c.err(line, "a <meta> declaration names one variable", .{});
    const an = names[0];
    if (an.has(.close)) return c.err(line, "cannot combine <meta> with <close>", .{});
    if (an.has(.group)) return c.err(line, "cannot combine <meta> with <group>", .{});
    if (an.has(.lazy)) return c.err(line, "cannot combine <meta> with <lazy>", .{});
    if (hasRuntimeAttribs(an)) return c.err(line, "cannot combine <meta> with runtime attributes", .{});
    if (values.len != 1) return c.err(line, "a <meta> variable needs one initializer", .{});
    if (c.discarding > 0 or !c.opts.meta_eval) {
        // Checked only: the declaration compiles as a constant local.
        var e: ExpDesc = .{};
        try expr(fs, values[0], &e);
        try adjustAssign(fs, 1, 1, &e);
        _ = try newLocalVar(fs, an.name.text, .const_);
        try adjustLocalVars(fs, 1);
        return;
    }
    const mv = switch (try metaEval(fs, values[0], line)) {
        .ok => |v| v,
        .err => |msg| return metaError(c, line, msg),
    };
    const tv = switch (try meta.intoTarget(c.meta.?, c.g, c.arena, mv)) {
        .ok => |v| v,
        .bad => |b| if (b.path.len == 0)
            return c.err(line, "meta value is a {s}", .{b.type_name})
        else
            return c.err(line, "meta value contains a {s} at {s}", .{ b.type_name, b.path }),
    };
    var k: ExpDesc = switch (tv.tag) {
        .nil => .{ .kind = .nil },
        .true => .{ .kind = .true_ },
        .false => .{ .kind = .false_ },
        .integer => .{ .kind = .kint, .ival = tv.asInt() },
        .float => .{ .kind = .kflt, .nval = tv.asFloat() },
        .string => .{ .kind = .kstr, .strval = tv.as(vm.object.String).bytes() },
        else => ExpDesc.init(.k, @intCast(try valueK(fs, tv))),
    };
    if (k.kind != .k and !c.opts.debug) {
        const vidx = try newLocalVar(fs, an.name.text, .ctc);
        const vd = getLocalVar(fs, vidx);
        vd.k = k;
        vd.meta_value = mv;
        try adjustLocalVars(fs, 1);
        return;
    }
    try exp2nextreg(fs, &k);
    const vidx = try newLocalVar(fs, an.name.text, .const_);
    const vd = getLocalVar(fs, vidx);
    vd.meta_value = mv;
    vd.meta_const = tv;
    try adjustLocalVars(fs, 1);
}

// ---------------------------------------------------------------------
// Lazy locals (`spec/design/lazy.md`)

/// A read of the lazy local `vd`: while its force function is set, calls
/// it, stores the value it returns, and clears it. Then reads the hidden
/// local that holds the value. The result is read-only. The declaring
/// function tests and writes these locals in place, and only the force
/// function captures the state of the computation, so a hot read costs
/// one test of a register that nothing captures.
fn lazyRead(fs: *FuncState, vd: *VarDesc, line: u32, v: *ExpDesc) Error!void {
    var f: ExpDesc = .{};
    try singleVar(fs, vd.lazy_force, line, &f);
    const base = fs.freereg;
    var skip: i32 = undefined;
    if (f.kind == .local) {
        skip = try condJump(fs, .test_, @intCast(f.info), 0, 0);
        try reserveRegs(fs, 1);
        try codeABC(fs, .move, base, @intCast(f.info), 0);
    } else {
        try exp2nextreg(fs, &f);
        skip = try condJump(fs, .test_, base, 0, 0);
    }
    try codeABC(fs, .call, base, 1, 2);
    var target: ExpDesc = .{};
    try singleVar(fs, vd.lazy_store, line, &target);
    var result = ExpDesc.init(.nonreloc, base);
    try storeVar(fs, &target, &result);
    var fv: ExpDesc = .{};
    try singleVar(fs, vd.lazy_force, line, &fv);
    var no: ExpDesc = .{ .kind = .false_ };
    try storeVar(fs, &fv, &no);
    try patchToHere(fs, skip);
    fs.freereg = base;
    try singleVar(fs, vd.lazy_store, line, v);
    v.node = &readonly_marker;
}

/// Builders of the syntax tree of a force function. Every node takes the
/// line and span of the declaration.
const Gen = struct {
    a: Allocator,
    line: u32,
    span: ast.Span,

    fn ex(g: Gen, kind: ast.Expr.Kind) Error!*ast.Expr {
        const e = try g.a.create(ast.Expr);
        e.* = .{ .span = g.span, .line = g.line, .kind = kind };
        return e;
    }
    fn name(g: Gen, text: []const u8) Error!*ast.Expr {
        return g.ex(.{ .name = .{ .text = text, .span = g.span } });
    }
    fn int(g: Gen, i: i64) Error!*ast.Expr {
        return g.ex(.{ .integer = i });
    }
    fn str(g: Gen, text: []const u8) Error!*ast.Expr {
        return g.ex(.{ .string = text });
    }
    fn bin(g: Gen, op: ast.BinOp, l: *ast.Expr, r: *ast.Expr) Error!*ast.Expr {
        return g.ex(.{ .binop = .{ .op = op, .lhs = l, .rhs = r } });
    }
    fn call(g: Gen, callee: *ast.Expr, args: []const *ast.Expr) Error!*ast.Expr {
        return g.ex(.{ .call = .{ .callee = callee, .args = try g.a.dupe(*ast.Expr, args), .args_kind = .parens } });
    }
    fn st(g: Gen, kind: ast.Stat.Kind) Error!*ast.Stat {
        const s = try g.a.create(ast.Stat);
        s.* = .{ .span = g.span, .line = g.line, .kind = kind };
        return s;
    }
    fn block(g: Gen, stats: []const *ast.Stat) Error!*ast.Block {
        const b = try g.a.create(ast.Block);
        b.* = .{ .stats = try g.a.dupe(*ast.Stat, stats), .span = g.span, .end_line = g.line };
        return b;
    }
    fn assign(g: Gen, target: []const u8, val: *ast.Expr) Error!*ast.Stat {
        const t = try g.a.alloc(*ast.Expr, 1);
        t[0] = try g.name(target);
        const vs = try g.a.alloc(*ast.Expr, 1);
        vs[0] = val;
        return g.st(.{ .assign = .{ .targets = t, .values = vs } });
    }
    fn local(g: Gen, names: []const []const u8, attribs: []const ast.Attrib, val: ?*ast.Expr) Error!*ast.Stat {
        const ns = try g.a.alloc(ast.AttName, names.len);
        for (names, ns) |n, *d| d.* = .{ .name = .{ .text = n, .span = g.span }, .attribs = try g.a.dupe(ast.Attrib, attribs) };
        var vs: []*ast.Expr = &.{};
        if (val) |x| {
            vs = try g.a.alloc(*ast.Expr, 1);
            vs[0] = x;
        }
        return g.st(.{ .local = .{ .names = ns, .values = vs } });
    }
    fn ifThen(g: Gen, cond: *ast.Expr, then: []const *ast.Stat, else_: ?[]const *ast.Stat) Error!*ast.Stat {
        const cl = try g.a.alloc(ast.IfClause, 1);
        cl[0] = .{ .cond = .{ .expr = cond }, .body = try g.block(then), .line = g.line };
        return g.st(.{ .if_ = .{ .clauses = cl, .else_ = if (else_) |e| try g.block(e) else null } });
    }
};

/// `local name <lazy> = exp`. The compiler declares hidden locals for the
/// value that reads see, the force function, and, captured only by the
/// force function, the state of the computation (1 pending, 0 computed,
/// or the thread computing it) and the computed value. `name` becomes a
/// read-only alias whose reads call the force function while it is set
/// (`lazyRead`).
fn lazyLocal(fs: *FuncState, names: []ast.AttName, values: []*ast.Expr, line: u32) Error!void {
    const c = fs.c;
    if (names.len != 1) return c.err(line, "a <lazy> declaration names one variable", .{});
    const an = names[0];
    if (an.has(.group)) return c.err(line, "cannot combine <lazy> with <group>", .{});
    if (values.len != 1) return c.err(line, "a <lazy> variable needs one initializer", .{});
    const a = c.arena;
    const x = an.name.text;
    const g: Gen = .{ .a = a, .line = line, .span = an.name.span };
    const store = try std.fmt.allocPrint(a, "(lazy {s})", .{x});
    const force = try std.fmt.allocPrint(a, "(lazy force {s})", .{x});
    const state = try std.fmt.allocPrint(a, "(lazy state {s})", .{x});
    const cache = try std.fmt.allocPrint(a, "(lazy cache {s})", .{x});
    const ok = "(lazy ok)";
    const val = "(lazy value)";
    var stats: std.ArrayList(*ast.Stat) = .empty;

    // Runtime attributes are evaluated once, before the initializer, as
    // for an ordinary local, and applied to the computed value.
    var handlers: std.ArrayList([]const u8) = .empty;
    for (an.attribs) |at| if (at == .runtime) {
        const h = try std.fmt.allocPrint(a, "(lazy attr {d} {s})", .{ handlers.items.len, x });
        try handlers.append(a, h);
        try stats.append(a, try g.local(&.{h}, &.{}, at.runtime));
    };
    try stats.append(a, try g.local(&.{store}, &.{}, null));
    try stats.append(a, try g.local(&.{state}, &.{}, try g.int(1)));
    try stats.append(a, try g.local(&.{cache}, &.{}, null));

    // The force function returns the value, computing it on its first
    // successful call.
    var body: std.ArrayList(*ast.Stat) = .empty;
    const wait = try g.st(.{ .expr = try g.call(try g.name(lazy.prefix ++ "lazywait"), &.{ try g.name(state), try g.str(x) }) });
    const rets = try a.alloc(*ast.Expr, 1);
    rets[0] = try g.name(cache);
    const done_return = try g.ifThen(try g.bin(.eq, try g.name(state), try g.int(0)), &.{try g.st(.{ .return_ = rets })}, null);
    try body.append(a, try g.st(.{ .while_ = .{
        .cond = .{ .expr = try g.bin(.ne, try g.name(state), try g.int(1)) },
        .body = try g.block(&.{ done_return, wait }),
    } }));
    try body.append(a, try g.assign(state, try g.call(try g.name(lazy.prefix ++ "running"), &.{})));
    try body.append(a, try g.local(&.{ ok, val }, &.{}, try g.ex(.{ .catch_ = .{ .handler = null, .body = values[0] } })));
    var success: std.ArrayList(*ast.Stat) = .empty;
    for (handlers.items) |h| {
        const r = "(lazy result)";
        const replaced = try g.ifThen(try g.bin(.ne, try g.name(r), try g.ex(.nil)), &.{try g.assign(val, try g.name(r))}, null);
        const apply = try g.local(&.{r}, &.{}, try g.call(try g.name(h), &.{ try g.str(x), try g.name(val) }));
        try success.append(a, try g.ifThen(try g.bin(.ne, try g.name(val), try g.ex(.nil)), &.{ apply, replaced }, null));
    }
    try success.append(a, try g.assign(cache, try g.name(val)));
    try success.append(a, try g.assign(state, try g.int(0)));
    const vrets = try a.alloc(*ast.Expr, 1);
    vrets[0] = try g.name(val);
    try success.append(a, try g.st(.{ .return_ = vrets }));
    const failure = [_]*ast.Stat{
        try g.assign(state, try g.int(1)),
        try g.st(.{ .expr = try g.call(try g.name(lazy.prefix ++ "rethrow"), &.{try g.name(val)}) }),
    };
    try body.append(a, try g.ifThen(try g.name(ok), success.items, &failure));
    const func = try a.create(ast.Function);
    func.* = .{ .params = &.{}, .is_vararg = false, .body = try g.block(body.items), .line = line, .end_line = line, .span = g.span, .name = x };
    try stats.append(a, try g.local(&.{force}, &.{}, try g.ex(.{ .function = func })));

    if (an.has(.close)) {
        // The value exists only after the first read, so a guard closes
        // it at the end of the scope when it was computed.
        const e = "(lazy error)";
        const close_body = try g.ifThen(try g.bin(.eq, try g.name(state), try g.int(0)), &.{
            try g.st(.{ .expr = try g.call(try g.name(lazy.prefix ++ "closevalue"), &.{ try g.name(cache), try g.name(e), try g.str(x) }) }),
        }, null);
        const params = try a.alloc(ast.Name, 1);
        params[0] = .{ .text = e, .span = g.span };
        const cf = try a.create(ast.Function);
        cf.* = .{ .params = params, .is_vararg = false, .body = try g.block(&.{close_body}), .line = line, .end_line = line, .span = g.span, .name = x };
        const guard = try std.fmt.allocPrint(a, "(lazy close {s})", .{x});
        try stats.append(a, try g.local(&.{guard}, &.{.close}, try g.call(try g.name(lazy.prefix ++ "closer"), &.{try g.ex(.{ .function = cf })})));
    }

    for (stats.items) |s| try statement(fs, s);
    const vidx = try newLocalVar(fs, x, .lazy);
    const vd = getLocalVar(fs, vidx);
    vd.readonly = true;
    vd.lazy_store = store;
    vd.lazy_force = force;
    try adjustLocalVars(fs, 1);
}

fn ifStat(fs: *FuncState, clauses: []ast.IfClause, else_block: ?*ast.Block, line: u32) Error!void {
    // The whole statement is one scope so condition variables stay visible
    // in later clauses.
    var outer: Block = undefined;
    enterBlock(fs, &outer, false);
    var escapes: i32 = no_jump;
    var decided = false;
    for (clauses) |cl| {
        fs.line = cl.line;
        if (try foldCondition(fs, cl.cond, cl.line)) |t| {
            try discardCond(fs, cl.cond, cl.line);
            if (decided or !t) {
                try discardBlock(fs, cl.body);
                continue;
            }
            // Folded true: compile the body unconditionally and discard
            // every later clause.
            try block(fs, cl.body);
            decided = true;
            continue;
        }
        if (decided) {
            try discardBlock(fs, cl.body);
            continue;
        }
        const f = try condition(fs, cl.cond, cl.line);
        try block(fs, cl.body);
        const j = try jump(fs);
        try concatJumps(fs, &escapes, j);
        try patchToHere(fs, f);
    }
    if (else_block) |eb| {
        if (decided) try discardBlock(fs, eb) else try block(fs, eb);
    }
    try patchToHere(fs, escapes);
    try leaveBlock(fs);
    _ = line;
}

/// Compiles a block for checking only and removes every trace of it.
fn discardBlock(fs: *FuncState, b: *ast.Block) Error!void {
    const saved = try DiscardMark.take(fs);
    fs.c.discarding += 1;
    defer fs.c.discarding -= 1;
    try block(fs, b);
    saved.restore(fs);
}

/// Compiles a folded condition for checking only, so that the operands
/// folding skipped still report their compile errors.
fn discardCond(fs: *FuncState, cond: ast.Cond, line: u32) Error!void {
    const saved = try DiscardMark.take(fs);
    fs.c.discarding += 1;
    defer fs.c.discarding -= 1;
    _ = try condition(fs, cond, line);
    saved.restore(fs);
}

/// The state that compiling discarded code changes.
const DiscardMark = struct {
    pc: usize,
    protos: usize,
    gotos: usize,
    handlers: usize,
    locvars: usize,
    line: u32,
    freereg: u8,
    /// The length of the pending `continue` list of each enclosing block,
    /// innermost first, since a discarded `continue` adds to one.
    continues: []usize,
    /// The exit list of each enclosing do expression, innermost first,
    /// since a discarded `provide` adds to one.
    exits: []i32,

    fn take(fs: *FuncState) Error!DiscardMark {
        var nd: usize = 0;
        var d = fs.do_ctx;
        while (d) |dd| : (d = dd.parent) nd += 1;
        const exits = try fs.c.arena.alloc(i32, nd);
        d = fs.do_ctx;
        var di: usize = 0;
        while (d) |dd| : (d = dd.parent) {
            exits[di] = dd.exits;
            di += 1;
        }
        var n: usize = 0;
        var b = fs.bl;
        while (b) |bb| : (b = bb.parent) n += 1;
        const lens = try fs.c.arena.alloc(usize, n);
        b = fs.bl;
        var i: usize = 0;
        while (b) |bb| : (b = bb.parent) {
            lens[i] = bb.continues.items.len;
            i += 1;
        }
        return .{
            .continues = lens,
            .exits = exits,
            .pc = fs.code.items.len,
            .protos = fs.protos.items.len,
            .gotos = fs.c.gotos.items.len,
            .handlers = fs.handlers.items.len,
            .locvars = fs.locvars.items.len,
            .line = fs.line,
            .freereg = fs.freereg,
        };
    }

    fn restore(m: DiscardMark, fs: *FuncState) void {
        fs.code.items.len = m.pc;
        fs.lines.items.len = m.pc;
        fs.protos.items.len = m.protos;
        fs.c.gotos.items.len = m.gotos;
        fs.handlers.items.len = m.handlers;
        fs.locvars.items.len = m.locvars;
        fs.line = m.line;
        fs.freereg = m.freereg;
        var b = fs.bl;
        var i: usize = 0;
        while (b) |bb| : (b = bb.parent) {
            if (i < m.continues.len) bb.continues.items.len = m.continues[i];
            i += 1;
        }
        var d = fs.do_ctx;
        i = 0;
        while (d) |dd| : (d = dd.parent) {
            if (i < m.exits.len) dd.exits = m.exits[i];
            i += 1;
        }
        if (fs.last_target > pc(fs)) fs.last_target = pc(fs);
    }
};

fn whileStat(fs: *FuncState, cond: ast.Cond, body: *ast.Block, line: u32) Error!void {
    // Wrap in one scope for condition variables.
    var outer: Block = undefined;
    enterBlock(fs, &outer, false);
    const start = getLabel(fs);
    const exit = try condition(fs, cond, line);
    var bl: Block = undefined;
    enterBlock(fs, &bl, true);
    // The body has its own block, so locals captured by closures are
    // closed on every iteration. `continue` lands before that close.
    var inner: Block = undefined;
    enterBlock(fs, &inner, false);
    try statList(fs, body.stats);
    try patchContinues(fs, &bl, getLabel(fs), true);
    try leaveBlock(fs);
    const back = try jump(fs);
    try patchList(fs, back, start);
    try leaveBlock(fs);
    try patchToHere(fs, exit);
    try leaveBlock(fs);
}

fn repeatStat(fs: *FuncState, body: *ast.Block, cond: *ast.Expr, line: u32) Error!void {
    const start = getLabel(fs);
    var loop: Block = undefined;
    enterBlock(fs, &loop, true);
    var scope: Block = undefined;
    enterBlock(fs, &scope, false);
    try statList(fs, body.stats);
    // `continue` lands before the condition, inside the body scope.
    try patchContinues(fs, &loop, getLabel(fs), false);
    var v: ExpDesc = .{};
    try expr(fs, cond, &v);
    if (v.kind == .nil) v.kind = .false_;
    try goIfTrue(fs, &v);
    const exit = v.f;
    if (scope.upval) {
        // Close upvalues of the body before looping back.
        const skip = try jump(fs);
        try patchToHere(fs, exit);
        try codeABC(fs, .close, blockLevel(fs, scope.nactvar), 0, 0);
        const back = try jump(fs);
        try patchList(fs, back, start);
        try patchToHere(fs, skip);
    } else {
        try patchList(fs, exit, start);
    }
    try leaveBlock(fs);
    try leaveBlock(fs);
    _ = line;
}

fn continueStat(fs: *FuncState, line: u32) Error!void {
    var bl = fs.bl;
    while (bl) |b| : (bl = b.parent) {
        if (b.is_loop) {
            const j = try jump(fs);
            try b.continues.append(fs.c.arena, .{ .name = "continue", .pc = j, .line = line, .nactvar = fs.nactvar });
            // Leaving blocks with captured locals needs a close at the
            // target.
            var x = fs.bl;
            while (x) |xb| : (x = xb.parent) {
                if (xb.upval) b.upval = true;
                if (xb == b) break;
            }
            return;
        }
    }
    return fs.c.err(line, "continue outside loop", .{});
}

/// Patches pending `continue` jumps of loop block `bl` to `target`.
/// `end_of_block` means the target is past the body's locals.
fn patchContinues(fs: *FuncState, bl: *Block, target: i32, end_of_block: bool) Error!void {
    if (bl.continues.items.len == 0) return;
    const level = if (end_of_block) bl.nactvar else fs.nactvar;
    for (bl.continues.items) |cont| {
        if (cont.nactvar < level) {
            const v = getLocalVar(fs, cont.nactvar);
            return fs.c.err(cont.line, "<continue> at line {d} jumps into the scope of '{s}'", .{ cont.line, v.name });
        }
    }
    var list: i32 = no_jump;
    for (bl.continues.items) |cont| try concatJumps(fs, &list, cont.pc);
    if (bl.upval) {
        // Jumps land on a CLOSE that releases the body's captured locals.
        const skip = try jump(fs);
        const here = getLabel(fs);
        try patchList(fs, list, here);
        try codeABC(fs, .close, blockLevel(fs, bl.nactvar), 0, 0);
        try patchToHere(fs, skip);
    } else {
        try patchList(fs, list, target);
    }
    bl.continues.clearRetainingCapacity();
}

fn numericFor(fs: *FuncState, name: ast.Name, start: *ast.Expr, limit: *ast.Expr, step: ?*ast.Expr, body: *ast.Block, line: u32) Error!void {
    var outer: Block = undefined;
    enterBlock(fs, &outer, true);
    const base = fs.freereg;
    var e: ExpDesc = .{};
    try expr(fs, start, &e);
    try exp2nextreg(fs, &e);
    try expr(fs, limit, &e);
    try exp2nextreg(fs, &e);
    if (step) |s| {
        try expr(fs, s, &e);
        try exp2nextreg(fs, &e);
    } else {
        try loadInt(fs, fs.freereg, 1);
        try reserveRegs(fs, 1);
    }
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    try adjustLocalVars(fs, 3);
    _ = try newLocalVar(fs, name.text, .const_);
    try forBody(fs, base, line, 1, false, body, &outer);
    try leaveBlock(fs);
}

fn genericFor(fs: *FuncState, names: []ast.Name, exprs: []*ast.Expr, body: *ast.Block, line: u32) Error!void {
    var outer: Block = undefined;
    enterBlock(fs, &outer, true);
    const base = fs.freereg;
    var e: ExpDesc = .{};
    const n = try explist(fs, exprs, &e);
    try adjustAssign(fs, 4, n, &e);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    for (names, 0..) |nm, i| _ = try newLocalVar(fs, nm.text, if (i == 0) .const_ else .regular);
    try adjustLocalVars(fs, 4);
    // The closing value may need closing.
    outer.upval = true;
    outer.inside_tbc = true;
    fs.needs_close = true;
    try checkStack(fs, 3);
    try forBody(fs, base, line, @intCast(names.len), true, body, &outer);
    try leaveBlock(fs);
}

/// `for a, b from explist do`: a generic loop whose one control
/// variable is the iterator's first value, the record. The body block
/// starts by reading each name as a field of the record into a fresh
/// local, so the loop builds no table of its own.
fn fromFor(fs: *FuncState, names: []ast.Name, exprs: []*ast.Expr, body: *ast.Block, line: u32) Error!void {
    var outer: Block = undefined;
    enterBlock(fs, &outer, true);
    const base = fs.freereg;
    var e: ExpDesc = .{};
    const n = try explist(fs, exprs, &e);
    try adjustAssign(fs, 4, n, &e);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for state)", .regular);
    _ = try newLocalVar(fs, "(for record)", .const_);
    try adjustLocalVars(fs, 4);
    outer.upval = true;
    outer.inside_tbc = true;
    fs.needs_close = true;
    try checkStack(fs, 3);
    const prep = try emitABx(fs, .tforprep, base, 0);
    var bl: Block = undefined;
    enterBlock(fs, &bl, false);
    try adjustLocalVars(fs, 1);
    try reserveRegs(fs, 1);
    const rec = base + 4;
    fs.line = line;
    const first = fs.freereg;
    try reserveRegs(fs, @intCast(names.len));
    for (names, 0..) |nm, i| try getFieldTo(fs, first + @as(u32, @intCast(i)), rec, nm.text);
    for (names) |nm| _ = try newLocalVar(fs, nm.text, .regular);
    try adjustLocalVars(fs, @intCast(names.len));
    try statList(fs, body.stats);
    try patchContinues(fs, &outer, getLabel(fs), true);
    try leaveBlock(fs);
    fs.line = line;
    const prep_target = getLabel(fs);
    if (prep_target - prep + 1 > opc.max_arg_bx) return fs.c.err(line, "control structure too long", .{});
    opc.setBx(&fs.code.items[@intCast(prep)], @intCast(prep_target - prep - 1));
    try codeABC(fs, .tforcall, base, 0, 1);
    const lp = try emitABx(fs, .tforloop, base, 0);
    opc.setBx(&fs.code.items[@intCast(lp)], @intCast(lp - prep));
    try leaveBlock(fs);
}

fn forBody(fs: *FuncState, base: u8, line: u32, nvars: u32, generic: bool, body: *ast.Block, loop: *Block) Error!void {
    const prep = if (generic) try emitABx(fs, .tforprep, base, 0) else try emitABx(fs, .forprep, base, 0);
    var bl: Block = undefined;
    enterBlock(fs, &bl, false);
    try adjustLocalVars(fs, nvars);
    try reserveRegs(fs, nvars);
    try statList(fs, body.stats);
    // Continue lands before the body block closes its captured locals.
    try patchContinues(fs, loop, getLabel(fs), true);
    try leaveBlock(fs);
    fs.line = line;
    const prep_target = getLabel(fs);
    // The loop instruction jumps back over the body and the call of a
    // generic loop, and its Bx field holds that distance.
    if (prep_target - prep + @intFromBool(generic) > opc.max_arg_bx) return fs.c.err(line, "control structure too long", .{});
    if (generic) {
        opc.setBx(&fs.code.items[@intCast(prep)], @intCast(prep_target - prep - 1));
        try codeABC(fs, .tforcall, base, 0, @intCast(nvars));
        const lp = try emitABx(fs, .tforloop, base, 0);
        opc.setBx(&fs.code.items[@intCast(lp)], @intCast(lp - prep));
    } else {
        const lp = try emitABx(fs, .forloop, base, 0);
        opc.setBx(&fs.code.items[@intCast(lp)], @intCast(lp - prep));
        opc.setBx(&fs.code.items[@intCast(prep)], @intCast(lp - prep - 1));
    }
}

fn returnStat(fs: *FuncState, vals: []*ast.Expr, line: u32) Error!void {
    var first = nvarstack(fs);
    var nret: i32 = 0;
    if (vals.len > 0) {
        var e: ExpDesc = .{};
        const n = try explist(fs, vals, &e);
        if (e.isMulti()) {
            try setReturns(fs, &e, -1);
            if (e.kind == .call and n == 1 and !(fs.bl.?.inside_tbc)) {
                const ci = &fs.code.items[@intCast(e.info)];
                if (opc.op(ci.*) == .call) opc.setOp(ci, .tailcall);
            }
            nret = -1;
        } else if (n == 1) {
            first = try exp2anyreg(fs, &e);
            nret = 1;
        } else {
            try exp2nextreg(fs, &e);
            nret = @intCast(n);
        }
    }
    fs.line = line;
    switch (nret) {
        0 => try codeABC(fs, .ret0, 0, 0, 0),
        1 => try codeABC(fs, .ret1, first, 0, 0),
        else => try codeABC(fs, .ret, first, @intCast(nret + 1), 0),
    }
}

fn labelStat(fs: *FuncState, name: []const u8, line: u32) Error!void {
    const c = fs.c;
    // A label may not repeat a visible label of the same function.
    var i = fs.first_label;
    while (i < c.labels.items.len) : (i += 1) {
        const l = c.labels.items[i];
        if (std.mem.eql(u8, l.name, name)) return c.err(line, "label '{s}' already defined on line {d}", .{ name, l.line });
    }
    _ = try createLabel(fs, name, line, fs.label_is_last);
}

// ---------------------------------------------------------------------
// Top-level helper

pub const CompileResult = union(enum) {
    ok: *Proto,
    err: []const u8,
};

/// Parses and compiles `src`. GC is paused for the duration.
pub fn compile(g: *vm.state.Global, src: []const u8, opts: Options) Allocator.Error!CompileResult {
    var arena_state = std.heap.ArenaAllocator.init(g.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: ?[]const u8 = null;
    const chunk = @import("../syntax/parser.zig").parse(g.gpa, arena, src, .{ .chunkname = opts.chunkname }, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return .{ .err = try g.gpa.dupe(u8, diag.?) },
    };
    const was_stopped = g.gc_stopped;
    g.gc_stopped = true;
    defer g.gc_stopped = was_stopped;
    var c = Compiler{ .gpa = g.gpa, .arena = arena, .g = g, .opts = opts };
    defer c.actvars.deinit(g.gpa);
    defer c.labels.deinit(g.gpa);
    defer c.gotos.deinit(g.gpa);
    defer if (c.meta) |m| m.close(g.gpa);
    const p = compileChunk(&c, chunk) catch |e| switch (e) {
        error.OutOfMemory => {
            return error.OutOfMemory;
        },
        error.CompileError => {
            return .{ .err = try g.gpa.dupe(u8, c.diag.?) };
        },
    };
    return .{ .ok = p };
}

/// Compiles an already parsed (and possibly transformed) chunk. The arena
/// must own the tree. GC is paused for the duration.
pub fn compileAst(g: *vm.state.Global, arena: Allocator, chunk: ast.Chunk, opts: Options) Allocator.Error!CompileResult {
    const was_stopped = g.gc_stopped;
    g.gc_stopped = true;
    defer g.gc_stopped = was_stopped;
    var c = Compiler{ .gpa = g.gpa, .arena = arena, .g = g, .opts = opts };
    defer c.actvars.deinit(g.gpa);
    defer c.labels.deinit(g.gpa);
    defer c.gotos.deinit(g.gpa);
    defer if (c.meta) |m| m.close(g.gpa);
    const p = compileChunk(&c, chunk) catch |e| switch (e) {
        error.OutOfMemory => {
            return error.OutOfMemory;
        },
        error.CompileError => {
            return .{ .err = try g.gpa.dupe(u8, c.diag.?) };
        },
    };
    return .{ .ok = p };
}

/// A goto to a visible label jumps backward right away. Otherwise it
/// waits for the label as a pending forward jump.
fn gotoStat(fs: *FuncState, name: []const u8, line: u32) Error!void {
    const c = fs.c;
    var i = c.labels.items.len;
    while (i > fs.first_label) {
        i -= 1;
        const lb = c.labels.items[i];
        if (!std.mem.eql(u8, lb.name, name)) continue;
        // Locals declared after the label are being left: close them.
        const lblevel = blockLevel(fs, lb.nactvar);
        if (nvarstack(fs) > lblevel) try codeABC(fs, .close, lblevel, 0, 0);
        const j = try jump(fs);
        try patchList(fs, j, lb.pc);
        return;
    }
    try newGoto(fs, name, line, try jump(fs));
}

/// Releases the buffers of a function whose compilation failed. Called by
/// the owner of the function state before it goes out of scope.
fn abortFunc(c: *Compiler, fs: *FuncState) void {
    {
        fs.code.deinit(c.gpa);
        fs.lines.deinit(c.gpa);
        fs.constants.deinit(c.gpa);
        fs.kcache.deinit(c.gpa);
        fs.protos.deinit(c.gpa);
        fs.upvals.deinit(c.gpa);
        fs.handlers.deinit(c.gpa);
        fs.locvars.deinit(c.gpa);
    }
    c.fs = fs.parent;
}

/// R[dest] = R[obj].name, keeping R[obj] alive (for `from`, which reads
/// several fields of one source).
fn getFieldTo(fs: *FuncState, dest: u32, obj: u8, name: []const u8) Error!void {
    const ki = try stringK(fs, name);
    if (ki <= 255) {
        try codeABC(fs, .getfield, dest, obj, ki);
    } else {
        _ = try emitABx(fs, .loadk, dest, ki);
        try codeABC(fs, .gettable, dest, obj, dest);
    }
}
