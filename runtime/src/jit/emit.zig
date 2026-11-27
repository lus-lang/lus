//! The template emitter. It walks the bytecode of a function once and
//! emits native code for each instruction: an inline fast path where one
//! pays off, and a call to the opcode's step routine for everything else.
//! A fast path that does not apply falls back to the step routine of the
//! same instruction, so the interpreter's definition decides every case
//! the templates leave out.
//!
//! Native code keeps no value in a machine register across instructions.
//! Registers, the frame, and the stack top live where the interpreter
//! keeps them, so every instruction boundary is a point where either tier
//! can continue the frame.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const value = @import("../vm/value.zig");
const gc = @import("../vm/gc.zig");
const interp = @import("../vm/interp.zig");
const table = @import("../vm/table.zig");
const opc = @import("../compile/opcodes.zig");
const jit = @import("jit.zig");
const helpers = @import("helpers.zig");
const aot = @import("aot.zig");
const Thread = state.Thread;
const Proto = object.Proto;
const Value = value.Value;
const Tag = value.Tag;
const Op = opc.Op;
const Step = interp.Step;

/// The assembler of the target.
pub const A = switch (builtin.cpu.arch) {
    .aarch64 => @import("a64.zig"),
    .x86_64 => @import("x64.zig"),
    .riscv64 => @import("rv64.zig"),
    .loongarch64 => @import("la64.zig"),
    .powerpc64le => @import("ppc64.zig"),
    .s390x => @import("s390x.zig"),
    .arm => @import("a32.zig"),
    else => @compileError("the JIT has no backend for this target"),
};
const Mem = A.Mem;

/// Stores a 64-bit word that is an integer or the bits of a float. On a
/// 64-bit target the value of a constant tells whether it can be an
/// address. On a 32-bit target every address is one word, so the store
/// names its word a literal, which keeps it away from the resolver of
/// code compiled ahead of time (`reloc.zig`).
pub fn storeLiteral(a: *A.Assembler, m: Mem, v: u64) void {
    if (@sizeOf(usize) == 4) a.storeImm64Reloc(m, v, .literal) else a.storeImm64(m, v);
}
const Label = A.Label;

const tag_int: u8 = @backingInt(Tag.integer);
const tag_float: u8 = @backingInt(Tag.float);
const tag_string: u8 = @backingInt(Tag.string);
/// The flag byte of a string and the bit that marks it interned.
const string_flags: i32 = object.String.flags_offset;
const string_interned_bit: u3 = @bitOffsetOf(object.String.Flags, "interned");
const tag_table: u8 = @backingInt(Tag.table);
const tag_closure: u8 = @backingInt(Tag.closure);
const tag_nil: u8 = @backingInt(Tag.nil);
const Frame = state.Frame;
const tl = table.layout;
const il = interp.layout;
const frame_size: i32 = @sizeOf(Frame);
const frame_shift: u6 = std.math.log2_int(usize, @sizeOf(Frame));
comptime {
    std.debug.assert(@sizeOf(Frame) == @as(usize, 1) << frame_shift);
    // The templates load sizes and addresses as words the size of a
    // pointer, which is 64 bits or, on 32-bit ARM, 32 bits.
    std.debug.assert(@sizeOf(usize) == 8 or builtin.cpu.arch == .arm);
    // An assembler that keeps the tag words of an integer and of a float
    // in registers names the words it expects.
    if (@hasDecl(A, "stored_words")) {
        std.debug.assert(A.stored_words[0] == Value.tagWordOf(tag_int) and A.stored_words[1] == Value.tagWordOf(tag_float));
    }
}

fn frameField(comptime name: []const u8) i32 {
    return @offsetOf(Frame, name);
}

/// Byte offsets inside runtime structures, measured on a live thread so
/// that they follow whatever layout the compiler chose.
const Layout = struct {
    stack_ptr: i32,
    global: i32,
    /// Offset in the global state of the count of pending finalizers.
    pending: i32,
    upval_loc: i32,
    stack_len: i32,
    frames_ptr: i32,
    frames_len: i32,
    frames_cap: i32,
    tbc_ptr: i32,
    tbc_len: i32,
    /// Offsets in a table of the pointer and the length of its hash part.
    hash_ptr: i32,
    hash_len: i32,

    fn of(l: *Thread) Layout {
        const b = @intFromPtr(l);
        const g = l.g;
        return .{
            .stack_len = @intCast(@intFromPtr(&l.stack.len) - b),
            .frames_ptr = @intCast(@intFromPtr(&l.frames.items.ptr) - b),
            .frames_len = @intCast(@intFromPtr(&l.frames.items.len) - b),
            .frames_cap = @intCast(@intFromPtr(&l.frames.capacity) - b),
            .tbc_ptr = @intCast(@intFromPtr(&l.tbc.items.ptr) - b),
            .tbc_len = @intCast(@intFromPtr(&l.tbc.items.len) - b),
            .hash_ptr = tl.hashPtr(),
            .hash_len = tl.hashLen(),
            .stack_ptr = @intCast(@intFromPtr(&l.stack.ptr) - b),
            .global = @offsetOf(Thread, "g"),
            .pending = @intCast(@intFromPtr(&g.tobefnz.items.len) - @intFromPtr(g)),
            .upval_loc = @offsetOf(object.Upvalue, "loc"),
        };
    }
};

/// Out-of-line code of an instruction, emitted after the main path of the
/// whole function so that the common case runs straight through.
const Cold = struct {
    entry: Label,
    pc: u32,
    kind: Kind,
    /// Where the main path continues, for kinds that return to it.
    resume_at: Label = 0,

    const Kind = union(enum) {
        /// Run the step routine of the instruction.
        step,
        /// Float operands of an arithmetic instruction.
        arith_float: Arith,
        /// Float operands of a comparison.
        compare_float: Compare,
        /// The slow part of the write barrier for the header in `t1`.
        barrier,
        /// A call of a value that is not a closure, which is most often
        /// a native function.
        native_call,
        /// The slow part of the table write barrier for the table in
        /// `t0`, after a store of register `v` under the constant `key`,
        /// or under a key that was already present.
        barrier_table: struct { v: u32, key: ?u32 },
        /// A call of a value that is not a closure in tail position.
        native_tail,
        /// A tail call to a Lus function through the helper.
        tail_helper,
        /// A table access through a fast-path helper. A key in a
        /// register must have the tag `key_tag`.
        table: TableCall,
        /// A store of a constant key that the prediction missed, with the
        /// table in `t0` and the predicted node in `t1`. A key that is
        /// absent from an empty predicted node is added here.
        field_insert: TableCall,
        /// A method lookup that missed in the receiver. `chain` is
        /// entered with the receiver table in `t0`, and the entry of the
        /// block with a receiver that is not a table.
        method: struct { call: TableCall, chain: Label, rb: u32 },
        /// A loop that became hot in baseline code, with the instruction
        /// its body starts at.
        opt_loop: u32,
        /// The helper of an array access.
        get_array: struct { t: u32, key: u32, dst: u32 },
        set_array: struct { t: u32, key: u32, v: u32 },
        get_index: struct { t: u32, index: u32, dst: u32 },
        length: struct { x: u32, dst: u32 },
    };
};

const TableCall = struct {
    helper: usize,
    t: Place,
    key: Place,
    v: Place,
    key_tag: ?u8 = null,
};

/// Where a value lives.
const Place = union(enum) {
    reg: u32,
    konst: u32,
    upval: u32,
};

/// An operand that is a register or a constant.
const Operand = union(enum) {
    reg: u32,
    int: i64,
    float: f64,
};

const ArithOp = enum { add, sub, mul, div };

const Arith = struct {
    op: ArithOp,
    dst: u32,
    x: Operand,
    y: Operand,
    /// Whether integer operands are valid here too, converted to floats.
    ints: bool,
};

const CompareOp = enum { lt, le, eq };

const Compare = struct {
    op: CompareOp,
    x: Operand,
    y: Operand,
    /// The comparison result that skips the following jump.
    skip_when: bool,
};

pub const Emitter = struct {
    /// The resolver of addresses when the state compiles in the form of
    /// code compiled ahead of time.
    aot: ?*aot.Context = null,
    a: A.Assembler,
    gpa: std.mem.Allocator,
    p: *Proto,
    g: *state.Global,
    lay: Layout,
    cold: std.ArrayList(Cold) = .empty,
    /// Label of instruction 0. The label of instruction `pc` follows.
    first: Label = 0,
    /// Where a step result other than "next" or "skip" goes. It is the
    /// status code at the start of the function or a jump to it that is
    /// close to the code being emitted.
    l_status: Label = 0,
    l_dispatch: Label = 0,
    l_exit: Label = 0,
    /// The first out-of-line block that is not emitted yet, and the code
    /// offset of the last flush.
    cold_next: usize = 0,
    flushed_at: u32 = 0,
    oom: bool = false,
    /// Whether a frame of the function can own an open upvalue, and a
    /// to-be-closed variable. A return tests only for what can exist.
    captures: bool = false,
    closes: bool = false,
    /// Offset of the code that a native call enters the function at, or
    /// zero when the function has none.
    call_entry: u32 = 0,
    /// Offset of the code that a native tail call enters the function
    /// at, or zero when the function has none.
    tail_entry: u32 = 0,
    /// The instruction that `step_label` runs the step routine of.
    step_pc: u32 = std.math.maxInt(u32),
    step_label: Label = 0,
    /// Whether the code counts calls and loop iterations for the
    /// optimizing tier.
    count: bool = false,
    /// Offset of the call entry behind its counter.
    call_entry_plain: u32 = 0,
    /// The instruction being emitted, and where its branches to other
    /// instructions go when the optimizing tier embeds a template.
    cur_pc: u32 = 0,
    redirect: ?*const Redirect = null,

    /// Maps a branch from the template of one instruction to the code of
    /// another instruction onto a label of the embedding code.
    pub const Redirect = struct {
        ctx: *anyopaque,
        target: *const fn (ctx: *anyopaque, from: u32, to: u32) Label,
    };

    pub fn init(gpa: std.mem.Allocator, l: *Thread, p: *Proto) Emitter {
        var e: Emitter = .{ .a = A.Assembler.init(gpa), .gpa = gpa, .p = p, .g = l.g, .lay = Layout.of(l) };
        if (l.g.jit.aot) |st| {
            // Ahead of time, every wide immediate goes through the
            // resolver (`aot.zig`).
            if (gpa.create(aot.Context)) |c| {
                c.* = aot.Context.init(gpa, l.g, st, p);
                e.aot = c;
                e.a.aot = true;
                if (@hasField(A.Assembler, "static")) e.a.static = st.static;
                e.a.resolver = c.resolver();
            } else |_| {}
        }
        return e;
    }

    /// Reports the addresses that the resolver could not name, when the
    /// state compiles in the form of code compiled ahead of time.
    pub fn reportAot(e: *Emitter) void {
        if (e.aot) |c| if (e.a.unrelocated > 0) aot.report(c, e.a.unrelocated);
    }

    pub fn deinit(e: *Emitter) void {
        if (e.aot) |c| {
            c.deinit();
            e.gpa.destroy(c);
        }
        e.a.deinit();
        e.cold.deinit(e.gpa);
    }

    pub fn bytes(e: *Emitter) []const u8 {
        return e.a.buf.items;
    }

    /// Emits the whole function. `offs` receives the code offset of every
    /// instruction. Returns false when the function cannot be compiled.
    pub fn run(e: *Emitter, offs: []u32) bool {
        const a = &e.a;
        const code = e.p.code;
        // The block starts with the entry sequence, a C function that
        // loads the pinned registers and jumps to the given address.
        a.prologue();
        e.reloadBp();
        a.jmpReg(A.entry_target);

        e.first = a.newLabels(code.len + 1);
        e.statusTail();
        e.scan();
        e.count = jit.opt.counts(e.g);
        // The call entry runs into the first instruction.
        if (!e.p.is_vararg) {
            e.tailEntry();
            e.callEntry();
        }

        const status = e.l_status;
        var pc: u32 = 0;
        while (pc < code.len) : (pc += 1) {
            // No temporary holds a value across instructions.
            inline for (.{ A.t0, A.t1, A.t2, A.t3, A.t4, A.t5, A.t6 }) |t| a.dead(t);
            a.bind(e.first + pc);
            e.instruction(pc, code[pc]);
            if (a.offset() - e.flushed_at >= flush_interval and pc + 1 < code.len) {
                // A long function emits its out-of-line code and its
                // constants at intervals, so that every conditional
                // branch and every constant load stays in range. The
                // code after this point reaches the status code through
                // a jump that is emitted here.
                const over = a.newLabel();
                const near_status = a.newLabel();
                a.jmp(over);
                e.flushCold();
                a.bind(near_status);
                a.jmp(status);
                a.flushPool();
                a.bind(over);
                e.l_status = near_status;
                e.flushed_at = a.offset();
            }
        }
        // Execution never runs off the end of a function.
        a.bind(e.first + pc);
        a.trap();
        e.flushCold();

        if (e.oom or !a.finish()) return false;
        for (offs, 0..) |*o, i| o.* = a.labelOffset(e.first + @as(u32, @intCast(i)));
        return true;
    }

    /// Emits the code that a step result other than "next" or "skip"
    /// reaches. Codes up to "dispatch" continue at the saved pc of the
    /// top frame, and the others leave native code.
    pub fn statusTail(e: *Emitter) void {
        const a = &e.a;
        e.l_status = a.newLabel();
        e.l_dispatch = a.newLabel();
        e.l_exit = a.newLabel();
        a.bind(e.l_status);
        a.jumpIfImm(.hi, A.ret0, @intCast(Step.dispatch), e.l_exit);
        a.bind(e.l_dispatch);
        a.mov(A.args[0], A.thread);
        a.callPair(@intFromPtr(&jit.dispatch));
        const l_interp = a.newLabel();
        a.jumpIfImm(.eq, A.ret0, 0, l_interp);
        a.mov(A.base, A.ret1);
        e.reloadBp();
        // The code after a call reads the result count of its callee
        // here, where a lean return leaves it. A frame that returned
        // through its step routine continues there too (`jit.dispatch`).
        a.movImm(A.t6, @intFromPtr(&e.g.jit.resume_count));
        a.loadWord(A.t6, .{ .base = A.t6 });
        a.jmpReg(A.ret0);
        a.bind(l_interp);
        a.movImm(A.ret0, Step.interpret);
        a.bind(e.l_exit);
        a.epilogue();
    }

    /// Finds what a return of the function has to test for. Only a
    /// closure made by this function opens an upvalue on one of its
    /// registers, and only two instructions mark a variable to be
    /// closed.
    pub fn scan(e: *Emitter) void {
        for (e.p.protos) |child| for (child.upvals) |d| {
            if (d.in_stack and !d.by_value) e.captures = true;
        };
        for (e.p.code) |ins| switch (opc.op(ins)) {
            .tbc, .tforprep => e.closes = true,
            else => {},
        };
    }

    /// Bytes of straight-line code between two flushes of the out-of-line
    /// code. The out-of-line code of that much straight-line code is a
    /// few times larger, and the sum stays well inside the megabyte that
    /// a conditional branch reaches on aarch64, and that a `jal`
    /// reaches on riscv64.
    const flush_interval = 64 * 1024;

    /// Emits the out-of-line code that is pending. A block may add more
    /// of its own, which follows in the same pass.
    pub fn flushCold(e: *Emitter) void {
        while (e.cold_next < e.cold.items.len) : (e.cold_next += 1) e.emitCold(e.cold.items[e.cold_next]);
    }

    // -----------------------------------------------------------------
    // Building blocks

    fn at(e: *const Emitter, pc: u32) Label {
        if (e.redirect) |r| return r.target(r.ctx, e.cur_pc, pc);
        return e.first + pc;
    }

    /// The payload word of register `r`.
    fn slot(r: u32) Mem {
        return .{ .base = A.bp, .disp = @intCast(r * 16) };
    }
    /// The tag word of register `r`. Its first byte is the tag.
    fn tagOf(r: u32) Mem {
        return .{ .base = A.bp, .disp = @intCast(r * 16 + 8) };
    }

    /// bp = stack + base * 16. Runs after anything that may have moved
    /// the stack or changed the frame.
    pub fn reloadBp(e: *Emitter) void {
        e.a.loadWord(A.bp, .{ .base = A.thread, .disp = e.lay.stack_ptr });
        e.a.addScaled(A.bp, A.bp, A.base, 4);
    }

    fn addCold(e: *Emitter, pc: u32, kind: Cold.Kind, resume_at: Label) Label {
        const entry = e.a.newColdLabel();
        e.cold.append(e.gpa, .{ .entry = entry, .pc = pc, .kind = kind, .resume_at = resume_at }) catch {
            e.oom = true;
        };
        return entry;
    }

    /// A label whose code runs the step routine of the instruction and
    /// continues wherever the step says.
    fn coldStep(e: *Emitter, pc: u32) Label {
        if (e.step_pc != pc) {
            e.step_label = e.addCold(pc, .step, 0);
            e.step_pc = pc;
        }
        return e.step_label;
    }

    /// Calls the step routine of the instruction at `pc` and continues
    /// at the next instruction, at the one after it, or wherever the top
    /// frame is, as the step reports.
    fn step(e: *Emitter, pc: u32, fallthrough: bool) void {
        const a = &e.a;
        const o = opc.op(e.p.code[pc]);
        a.mov(A.args[0], A.thread);
        a.movImm(A.args[1], pc + 1);
        if (@hasDecl(A.Assembler, "loadStop")) a.loadStop(A.args[2]) else a.mov(A.args[2], A.stop);
        a.movImmReloc(A.args[3], e.p.code[pc], .literal);
        a.call(@intFromPtr(helpers.steps[@backingInt(o)]));
        a.jumpIfImm(.hi, A.ret0, @intCast(Step.skip), e.l_status);
        e.reloadBp();
        a.jumpIfImm(.ne, A.ret0, 0, e.at(@min(pc + 2, @as(u32, @intCast(e.p.code.len)))));
        if (!fallthrough) a.jmp(e.at(pc + 1));
    }

    fn storeTag(e: *Emitter, r: u32, tag: u8) void {
        e.a.storeImm64(tagOf(r), Value.tagWordOf(tag));
    }

    /// Stores a constant value into a register. Only the payload of an
    /// object is an address.
    fn storeConst(e: *Emitter, r: u32, v: Value) void {
        const w: *const [2]u64 = @ptrCast(&v);
        if (v.tag.isCollectable()) e.a.storeImm64(slot(r), w[0]) else storeLiteral(&e.a, slot(r), w[0]);
        e.a.storeImm64(tagOf(r), w[1]);
    }

    fn loadInt(e: *Emitter, dst: A.Reg, o: Operand) void {
        switch (o) {
            .reg => |r| e.a.load64(dst, slot(r)),
            .int => |v| e.a.movImmReloc(dst, @bitCast(v), .literal),
            .float => unreachable,
        }
    }

    /// Loads a float operand. An integer constant converts.
    fn loadFloat(e: *Emitter, dst: A.FReg, o: Operand) void {
        switch (o) {
            .reg => |r| e.a.loadF(dst, slot(r)),
            .int => |v| {
                e.a.movImmReloc(A.t0, @bitCast(@as(f64, @floatFromInt(v))), .literal);
                e.a.bitsToFloat(dst, A.t0);
            },
            .float => |v| {
                e.a.movImmReloc(A.t0, @bitCast(v), .literal);
                e.a.bitsToFloat(dst, A.t0);
            },
        }
    }

    /// Branches to `miss` unless the operand is a register holding `tag`.
    /// Constants were checked when the instruction was compiled.
    fn guard(e: *Emitter, o: Operand, tag: u8, miss: Label) void {
        switch (o) {
            .reg => |r| e.a.jumpIfByte(.ne, tagOf(r), tag, miss),
            else => {},
        }
    }

    fn constOperand(e: *Emitter, k: u32) ?Operand {
        const v = e.p.constants[k];
        return switch (v.tag) {
            .integer => .{ .int = v.asInt() },
            .float => .{ .float = v.asFloat() },
            else => null,
        };
    }

    // -----------------------------------------------------------------
    // Instructions

    pub fn instruction(e: *Emitter, pc: u32, ins: u32) void {
        const a = &e.a;
        e.cur_pc = pc;
        const o = opc.op(ins);
        const ra: u32 = opc.a(ins);
        const rb: u32 = opc.b(ins);
        const rc: u32 = opc.c(ins);
        switch (o) {
            // The operand word of the previous instruction.
            .extraarg => a.trap(),

            .move => a.copy16(slot(ra), slot(rb)),
            .loadk => e.storeConst(ra, e.p.constants[opc.bx(ins)]),
            .loadi => e.storeConst(ra, Value.int(opc.sbx(ins))),
            .loadf => e.storeConst(ra, Value.float(@floatFromInt(opc.sbx(ins)))),
            .loadfalse => e.storeConst(ra, .false),
            .loadtrue => e.storeConst(ra, .true),
            .loadnil => {
                if (rb > 8) return e.step(pc, true);
                var i: u32 = 0;
                while (i <= rb) : (i += 1) e.storeConst(ra + i, .nil);
            },

            .getupval => {
                e.loadUpvalLoc(A.t0, A.t1, rb);
                a.copy16(slot(ra), .{ .base = A.t0 });
            },
            .setupval => {
                e.loadUpvalLoc(A.t0, A.t1, rb);
                a.copy16(.{ .base = A.t0 }, slot(ra));
                const done = a.newLabel();
                const slow = e.addCold(pc, .barrier, done);
                a.jumpIfBit(.{ .base = A.t1, .disp = @offsetOf(gc.Header, "flags") }, 0, true, slow);
                a.bind(done);
            },

            .getfield => e.fieldGet(pc, .{ .reg = rb }, rc, ra),
            .gettabup => e.fieldGet(pc, .{ .upval = rb }, rc, ra),
            .setfield => e.fieldSet(pc, .{ .reg = ra }, rb, rc),
            .settabup => e.fieldSet(pc, .{ .upval = ra }, rb, rc),
            .self => e.method(pc, ra, rb, rc),
            .gettable => {
                // An integer key reads the array part. A string key takes
                // the inline cache out of line.
                const done = a.newLabel();
                const by_name: Cold.Kind = .{ .table = .{ .helper = @intFromPtr(&helpers.getStr), .t = .{ .reg = rb }, .key = .{ .reg = rc }, .v = .{ .reg = ra }, .key_tag = tag_string } };
                const miss = e.addCold(pc, .{ .get_array = .{ .t = rb, .key = rc, .dst = ra } }, done);
                a.jumpIfByte(.ne, tagOf(rb), tag_table, e.coldStep(pc));
                a.jumpIfByte(.ne, tagOf(rc), tag_int, e.addCold(pc, by_name, done));
                a.load64(A.t0, slot(rb));
                a.load64(A.t1, slot(rc));
                a.addImm(A.t1, -1);
                // The helper reads only the array part, so a key outside
                // it takes the step routine at once.
                e.arrayGet(ra, e.coldStep(pc), miss, done);
                a.bind(done);
            },
            .getindex => {
                const done = a.newLabel();
                const miss = e.addCold(pc, .{ .get_index = .{ .t = rb, .index = rc, .dst = ra } }, done);
                // Index zero is never in the array part.
                if (rc == 0) {
                    a.jmp(miss);
                } else {
                    a.jumpIfByte(.ne, tagOf(rb), tag_table, miss);
                    a.load64(A.t0, slot(rb));
                    a.movImm(A.t1, rc - 1);
                    e.arrayGet(ra, miss, miss, done);
                }
                a.bind(done);
            },
            .settable => {
                const done = a.newLabel();
                const by_name: Cold.Kind = .{ .table = .{ .helper = @intFromPtr(&helpers.setStr), .t = .{ .reg = ra }, .key = .{ .reg = rb }, .v = .{ .reg = rc }, .key_tag = tag_string } };
                const miss = e.addCold(pc, .{ .set_array = .{ .t = ra, .key = rb, .v = rc } }, done);
                a.jumpIfByte(.ne, tagOf(ra), tag_table, e.coldStep(pc));
                a.jumpIfByte(.ne, tagOf(rb), tag_int, e.addCold(pc, by_name, done));
                a.load64(A.t0, slot(ra));
                a.load64(A.t1, slot(rb));
                a.addImm(A.t1, -1);
                e.arraySet(pc, rc, e.coldStep(pc), miss, done);
                a.bind(done);
            },
            .concat, .interp => {
                // A short join of strings and integers runs without the
                // step routine. Anything else takes it.
                const done = a.newLabel();
                a.mov(A.args[0], A.thread);
                a.lea(A.args[1], slot(ra));
                a.movImm(A.args[2], rb);
                a.call(@intFromPtr(&helpers.concatShort));
                a.jumpIfImm(.ne, A.ret0, 0, done);
                e.step(pc, true);
                a.bind(done);
            },
            .getctx, .setctx => {
                // A read, and a write to an array the coroutine owns, run
                // without the step routine (`spec/design/context.md`).
                const done = a.newLabel();
                a.mov(A.args[0], A.thread);
                if (o == .getctx) {
                    a.lea(A.args[1], slot(ra));
                    a.lea(A.args[2], slot(rb));
                    a.call(@intFromPtr(&helpers.ctxGet));
                } else {
                    a.lea(A.args[1], slot(ra));
                    a.lea(A.args[2], slot(rb));
                    a.call(@intFromPtr(&helpers.ctxSet));
                }
                a.jumpIfImm(.ne, A.ret0, 0, done);
                e.step(pc, true);
                a.bind(done);
            },
            .tforcall => {
                // `next` and `ipairs` over plain tables step without a
                // native frame. Anything else takes the step routine.
                const done = a.newLabel();
                a.mov(A.args[0], A.thread);
                a.lea(A.args[1], slot(ra));
                a.movImm(A.args[2], opc.c(ins));
                a.call(@intFromPtr(&helpers.tforStep));
                a.jumpIfImm(.ne, A.ret0, 0, done);
                e.step(pc, true);
                a.bind(done);
            },
            .len => {
                // The character count of a string is a field of it. A
                // table takes the helper, which searches for a border.
                const done = a.newLabel();
                a.jumpIfByte(.ne, tagOf(rb), tag_string, e.addCold(pc, .{ .length = .{ .x = rb, .dst = ra } }, done));
                a.load64(A.t0, slot(rb));
                a.load32(A.t0, .{ .base = A.t0, .disp = object.String.chars_offset });
                a.store64(A.t0, slot(ra));
                e.storeTag(ra, tag_int);
                a.bind(done);
            },

            .add => e.arith(pc, .add, ra, .{ .reg = rb }, .{ .reg = rc }),
            .sub => e.arith(pc, .sub, ra, .{ .reg = rb }, .{ .reg = rc }),
            .mul => e.arith(pc, .mul, ra, .{ .reg = rb }, .{ .reg = rc }),
            .div => e.arith(pc, .div, ra, .{ .reg = rb }, .{ .reg = rc }),
            inline .addk, .subk, .mulk, .divk => |ko| {
                const k = e.constOperand(rc) orelse return e.step(pc, true);
                e.arith(pc, switch (ko) {
                    .addk => .add,
                    .subk => .sub,
                    .mulk => .mul,
                    .divk => .div,
                    else => unreachable,
                }, ra, .{ .reg = rb }, k);
            },
            .addi => e.arith(pc, .add, ra, .{ .reg = rb }, .{ .int = opc.sc(ins) }),
            .modk, .idivk => {
                const k = e.p.constants[rc];
                if (k.tag != .integer or k.asInt() == 0 or k.asInt() == -1) return e.step(pc, true);
                e.divide(pc, o == .modk, ra, rb, .{ .int = k.asInt() });
            },
            .mod, .idiv => e.divide(pc, o == .mod, ra, rb, .{ .reg = rc }),
            .band, .bor, .bxor => {
                const slow = e.coldStep(pc);
                a.jumpIfByte(.ne, tagOf(rb), tag_int, slow);
                a.jumpIfByte(.ne, tagOf(rc), tag_int, slow);
                a.load64(A.t0, slot(rb));
                a.load64(A.t1, slot(rc));
                switch (o) {
                    .band => a.@"and"(A.t0, A.t1),
                    .bor => a.@"or"(A.t0, A.t1),
                    else => a.xor(A.t0, A.t1),
                }
                a.store64(A.t0, slot(ra));
                e.storeTag(ra, tag_int);
            },
            .unm => {
                a.jumpIfByte(.ne, tagOf(rb), tag_int, e.coldStep(pc));
                a.load64(A.t0, slot(rb));
                a.neg(A.t0);
                a.store64(A.t0, slot(ra));
                e.storeTag(ra, tag_int);
            },
            .not => {
                const truthy = a.newLabel();
                const done = a.newLabel();
                a.load8(A.t0, tagOf(rb));
                a.jumpIfImm(.hi, A.t0, @backingInt(Tag.false), truthy);
                e.storeConst(ra, .true);
                a.jmp(done);
                a.bind(truthy);
                e.storeConst(ra, .false);
                a.bind(done);
            },

            .jmp => {
                const off = opc.sj(ins);
                const target: u32 = @intCast(@as(i64, pc) + 1 + off);
                if (off < 0) {
                    // A backward jump is a safe point for finalizers,
                    // which the step routine runs.
                    a.loadWord(A.t0, .{ .base = A.thread, .disp = e.lay.global });
                    a.loadWord(A.t0, .{ .base = A.t0, .disp = e.lay.pending });
                    a.jumpIfImm(.ne, A.t0, 0, e.coldStep(pc));
                    e.countLoop(pc, target);
                }
                a.jmp(e.at(target));
            },
            .lt => e.compare(pc, .lt, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .le => e.compare(pc, .le, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .eq => e.compare(pc, .eq, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .lti => e.compare(pc, .lt, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0),
            .lei => e.compare(pc, .le, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0),
            .gti => e.compare(pc, .lt, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0),
            .gei => e.compare(pc, .le, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0),
            .eqk => e.equalConstant(pc, ra, e.p.constants[rb], rc != 0),
            .test_ => {
                if (!e.jumpFollows(pc)) return e.step(pc, true);
                a.load8(A.t0, tagOf(ra));
                // Skip the jump when the truth of the value differs from C.
                a.jumpIfImm(if (rc != 0) .ls else .hi, A.t0, @backingInt(Tag.false), e.at(pc + 2));
            },
            .testset => {
                if (!e.jumpFollows(pc)) return e.step(pc, true);
                a.load8(A.t0, tagOf(rb));
                a.jumpIfImm(if (rc != 0) .ls else .hi, A.t0, @backingInt(Tag.false), e.at(pc + 2));
                a.copy16(slot(ra), slot(rb));
            },
            .testnil => {
                if (!e.jumpFollows(pc)) return e.step(pc, true);
                a.load8(A.t0, tagOf(ra));
                // Skip the jump when "is nil" differs from C.
                a.jumpIfImm(if (rc != 0) .ne else .eq, A.t0, @backingInt(Tag.nil), e.at(pc + 2));
            },

            .forloop => {
                // The integer loop: R[A+1] counts the iterations left.
                a.jumpIfByte(.ne, tagOf(ra), tag_int, e.coldStep(pc));
                a.load64(A.t0, slot(ra + 1));
                a.jumpIfImm(.eq, A.t0, 0, e.at(pc + 1));
                a.addImm(A.t0, -1);
                a.store64(A.t0, slot(ra + 1));
                a.load64(A.t1, slot(ra));
                a.load64(A.t2, slot(ra + 2));
                a.add(A.t1, A.t2);
                a.store64(A.t1, slot(ra));
                a.store64(A.t1, slot(ra + 3));
                e.storeTag(ra + 3, tag_int);
                e.countLoop(pc, pc + 1 - opc.bx(ins));
                a.jmp(e.at(pc + 1 - opc.bx(ins)));
            },
            .tforloop => {
                a.load8(A.t0, tagOf(ra + 4));
                a.jumpIfImm(.eq, A.t0, @backingInt(Tag.nil), e.at(pc + 1));
                a.copy16(slot(ra + 2), slot(ra + 4));
                e.countLoop(pc, pc + 1 - opc.bx(ins));
                a.jmp(e.at(pc + 1 - opc.bx(ins)));
            },

            .call => {
                // A callee with a call entry is a Lus function with fixed
                // parameters and native code. The entry pushes the frame
                // and does not come back. It returns here, with nothing
                // changed, when the call needs the step routine.
                const slow = e.coldStep(pc);
                const done = a.newLabel();
                a.jumpIfByte(.ne, tagOf(ra), tag_closure, e.addCold(pc, .native_call, done));
                a.load64(A.t0, slot(ra));
                a.loadWord(A.t1, .{ .base = A.t0, .disp = @offsetOf(object.Closure, "proto") });
                a.loadWord(A.t2, .{ .base = A.t1, .disp = @offsetOf(Proto, "jit_entry") });
                a.jumpIfImm(.eq, A.t2, 0, slow);
                a.movImm(A.t3, pc + 1);
                a.lea(A.t4, .{ .base = A.base, .disp = @intCast(ra + 1) });
                a.movImm(A.t5, @as(u32, @bitCast(@as(i32, @intCast(rc)) - 1)));
                if (rb != 0) {
                    a.movImm(A.t6, rb - 1);
                } else {
                    // The arguments run up to the stack top.
                    a.load32(A.t6, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                    a.subWord(A.t6, A.t4);
                }
                a.callReg(A.t2);
                // The callee returns to the code after this jump, with its
                // result count in t6 and its results already in place from
                // R[A] on.
                a.jmp(slow);
                if (rc == 0) {
                    // Every result is wanted, and the stack top marks
                    // their end.
                    a.mov(A.t0, A.base);
                    a.addWord(A.t0, A.t6);
                    a.addImmWord(A.t0, @intCast(ra));
                } else {
                    // Results the callee did not return are nil, and the
                    // register window of this function comes back. A
                    // lean return passes at most one result. The general
                    // return, which resumes here with the wanted count,
                    // has stored every wanted result already.
                    if (rc >= 2) {
                        const has_one = a.newLabel();
                        const has_all = a.newLabel();
                        if (rc >= 3) a.jumpIfImm(.hs, A.t6, @intCast(rc - 1), has_all);
                        a.jumpIfImm(.ne, A.t6, 0, has_one);
                        e.storeConst(ra, .nil);
                        a.bind(has_one);
                        var i: u32 = 1;
                        while (i + 1 < rc) : (i += 1) e.storeConst(ra + i, .nil);
                        a.bind(has_all);
                    }
                    a.mov(A.t0, A.base);
                    a.addImmWord(A.t0, e.p.max_stack);
                }
                a.store32(A.t0, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                a.bind(done);
            },
            .tailcall => {
                // A callee with a tail entry is a Lus function with fixed
                // parameters and native code. The entry replaces the
                // running frame and does not come back. It returns here,
                // with nothing changed, when the stack must grow.
                const helper = e.addCold(pc, .tail_helper, 0);
                // A native function is called and its results returned.
                a.jumpIfByte(.ne, tagOf(ra), tag_closure, e.addCold(pc, .native_tail, 0));
                a.load64(A.t0, slot(ra));
                a.loadWord(A.t1, .{ .base = A.t0, .disp = @offsetOf(object.Closure, "proto") });
                a.loadWord(A.t2, .{ .base = A.t1, .disp = @offsetOf(Proto, "jit_tail") });
                a.jumpIfImm(.eq, A.t2, 0, helper);
                if (e.captures) {
                    // The helper closes the upvalues of this frame.
                    const none = a.newLabel();
                    a.loadWord(A.t1, .{ .base = A.thread, .disp = @offsetOf(Thread, "open_upvals") });
                    a.jumpIfImm(.eq, A.t1, 0, none);
                    a.load32(A.t1, .{ .base = A.t1, .disp = @offsetOf(object.Upvalue, "level") });
                    a.jumpIf(.hs, A.t1, A.base, helper);
                    a.bind(none);
                }
                a.lea(A.t4, slot(ra));
                if (rb != 0) {
                    a.movImm(A.t6, rb - 1);
                } else {
                    // The arguments run up to the stack top.
                    a.load32(A.t6, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                    a.subWord(A.t6, A.base);
                    a.addImmWord(A.t6, -@as(i32, @intCast(ra + 1)));
                }
                a.callReg(A.t2);
                a.jmp(helper);
            },
            .ret0, .ret1 => e.leanReturn(pc, @intFromBool(o == .ret1), ra),

            // An instruction that never changes the pc by itself falls
            // through to its successor.
            else => e.step(pc, true),
        }
    }

    /// The code a native call enters the function at. The caller passes
    /// the closure in t0, the pc to save in t3, the base of the new frame
    /// in t4, the wanted result count in t5, and the argument count in
    /// t6. The entry does what `interp.enterLus` does. It returns to the
    /// caller, with nothing changed, when finalizers are pending or when
    /// the frame list or the stack must grow.
    ///
    /// The frame it pushes is a lean frame. Every field of the frame is
    /// written, so the collector, tracebacks, the unwinder, and the
    /// interpreter read it like any other frame. The fields that are the
    /// same for every lean frame sit together (`state.Frame`), so the
    /// frame takes six stores.
    pub fn callEntry(e: *Emitter) void {
        const a = &e.a;
        const lay = e.lay;
        const max_stack: i32 = e.p.max_stack;
        const fail = a.newLabel();
        const thread: A.Reg = A.thread;
        e.call_entry = a.offset();
        if (e.count) {
            // A call counts toward the optimizing tier. The call that
            // brings the counter to zero goes through the step routine,
            // and `jit.dispatch` then compiles the function.
            a.movImm(A.t1, @intFromPtr(&e.p.opt_hot));
            a.load32(A.t2, .{ .base = A.t1 });
            a.addImmWord(A.t2, -1);
            a.store32(A.t2, .{ .base = A.t1 });
            a.jumpIfZero32(A.t2, true, fail);
        }
        e.call_entry_plain = a.offset();
        a.loadWord(A.t1, .{ .base = thread, .disp = lay.global });
        a.loadWord(A.t1, .{ .base = A.t1, .disp = lay.pending });
        a.jumpIfImm(.ne, A.t1, 0, fail);
        a.loadWord(A.t1, .{ .base = thread, .disp = lay.frames_len });
        a.jumpIfMemWord(.eq, A.t1, .{ .base = thread, .disp = lay.frames_cap }, fail);
        a.mov(A.t2, A.t4);
        a.addWord(A.t2, A.t6);
        a.addImmWord(A.t2, max_stack + 8);
        a.jumpIfMemWord(.hi, A.t2, .{ .base = thread, .disp = lay.stack_len }, fail);

        // Nothing fails from here on.
        // t2 = the new frame, one past the caller's.
        a.loadWord(A.t2, .{ .base = thread, .disp = lay.frames_ptr });
        a.addScaled(A.t2, A.t2, A.t1, frame_shift);
        a.addImmWord(A.t1, 1);
        a.storeWord(A.t1, .{ .base = thread, .disp = lay.frames_len });
        a.store32(A.t3, .{ .base = A.t2, .disp = frameField("pc") - frame_size });
        const zero: A.Reg = A.Assembler.zero_reg orelse blk: {
            a.movImm(A.t3, 0);
            break :blk A.t3;
        };
        a.storePairWord(A.t0, zero, .{ .base = A.t2, .disp = frameField("closure") });
        a.store64(zero, .{ .base = A.t2, .disp = frameField("pc") });
        // The function value sits below the base, and the result goes
        // there.
        a.lea(A.t1, .{ .base = A.t4, .disp = -1 });
        a.storePair32(A.t1, A.t4, .{ .base = A.t2, .disp = frameField("func") });
        a.storePair32(A.t1, A.t5, .{ .base = A.t2, .disp = frameField("ret") });
        storeLiteral(a, .{ .base = A.t2, .disp = frameField("boundary") }, Frame.lean_flags);
        // The caller continues after the jump that follows its call.
        a.linkPastJump(A.t3);
        a.dropLink();
        a.storeWord(A.t3, .{ .base = A.t2, .disp = frameField("resume_at") });
        a.addImmWord(A.t1, 1 + max_stack);
        a.store32(A.t1, .{ .base = thread, .disp = @offsetOf(Thread, "top") });
        a.mov(A.base, A.t4);
        e.reloadBp();

        e.clearRegisters();
        const start = a.newLabel();
        a.jmp(start);
        a.bind(fail);
        a.retLocal();
        a.bind(start);
    }

    /// Clears the registers of a function that was just entered with
    /// the argument count in t6: missing parameters and the registers
    /// above the parameters start nil.
    fn clearRegisters(e: *Emitter) void {
        const a = &e.a;
        const p = e.p;
        const np: u32 = p.num_params;
        a.zeroPrepare();
        if (np > 0) {
            const fixed = a.newLabel();
            const loop = a.newLabel();
            a.jumpIfImm(.hs, A.t6, @intCast(np), fixed);
            a.bind(loop);
            a.addScaled(A.t1, A.bp, A.t6, 4);
            a.zero16(.{ .base = A.t1 });
            a.addImmWord(A.t6, 1);
            a.jumpIfImm(.lo, A.t6, @intCast(np), loop);
            a.bind(fixed);
        }
        const count: u32 = @as(u32, p.max_stack) - np;
        if (count <= 16) {
            var r: u32 = np;
            while (r < p.max_stack) : (r += 1) a.zero16(slot(r));
        } else {
            const loop = a.newLabel();
            a.lea(A.t1, slot(np));
            a.movImm(A.t3, count);
            a.bind(loop);
            a.zero16(.{ .base = A.t1 });
            a.addImmWord(A.t1, 16);
            a.addImmWord(A.t3, -1);
            a.jumpIfImm(.ne, A.t3, 0, loop);
        }
    }

    /// The code a native tail call enters the function at. The caller
    /// passes the closure in t0, the address of the stack slot that holds
    /// it in t4, and the argument count in t6, and it has no open upvalue
    /// left. The entry does what the closure branch of the interpreter's
    /// `tailcall` does: it moves the callee and its arguments down to the
    /// return slot of the running frame and makes that frame the frame
    /// of the callee. What the frame owes its caller stays in it: the
    /// return slot, the wanted count, the boundary and lean flags, the
    /// finish action, and the address its caller continues at. The entry
    /// returns to the caller, with nothing changed, when the stack must
    /// grow.
    pub fn tailEntry(e: *Emitter) void {
        const a = &e.a;
        const lay = e.lay;
        const max_stack: i32 = e.p.max_stack;
        const thread: A.Reg = A.thread;
        const fail = a.newLabel();
        const loop = a.newLabel();
        e.tail_entry = a.offset();
        // t1 = the end of the running frame, t2 = its return slot.
        a.loadWord(A.t1, .{ .base = thread, .disp = lay.frames_len });
        a.loadWord(A.t2, .{ .base = thread, .disp = lay.frames_ptr });
        a.addScaled(A.t1, A.t2, A.t1, frame_shift);
        a.load32(A.t2, .{ .base = A.t1, .disp = frameField("ret") - frame_size });
        a.mov(A.t3, A.t2);
        a.addWord(A.t3, A.t6);
        a.addImmWord(A.t3, max_stack + 9);
        a.jumpIfMemWord(.hi, A.t3, .{ .base = thread, .disp = lay.stack_len }, fail);

        // Nothing fails from here on.
        a.dropLink();
        a.loadWord(A.t3, .{ .base = thread, .disp = lay.stack_ptr });
        a.addScaled(A.t3, A.t3, A.t2, 4);
        a.mov(A.t5, A.t6);
        a.addImmWord(A.t5, 1);
        a.bind(loop);
        a.copy16(.{ .base = A.t3 }, .{ .base = A.t4 });
        a.addImmWord(A.t3, 16);
        a.addImmWord(A.t4, 16);
        a.addImmWord(A.t5, -1);
        a.jumpIfImm(.ne, A.t5, 0, loop);

        a.storeWord(A.t0, .{ .base = A.t1, .disp = frameField("closure") - frame_size });
        a.lea(A.t4, .{ .base = A.t2, .disp = 1 });
        a.storePair32(A.t2, A.t4, .{ .base = A.t1, .disp = frameField("func") - frame_size });
        a.movImm(A.t3, 0);
        a.movImm(A.t5, 1);
        a.store64(A.t3, .{ .base = A.t1, .disp = frameField("pc") - frame_size });
        a.store8(A.t5, .{ .base = A.t1, .disp = frameField("tail") - frame_size });
        a.store8(A.t3, .{ .base = A.t1, .disp = frameField("hook") - frame_size });
        a.lea(A.t3, .{ .base = A.t4, .disp = max_stack });
        a.store32(A.t3, .{ .base = thread, .disp = @offsetOf(Thread, "top") });
        a.mov(A.base, A.t4);
        e.reloadBp();
        e.clearRegisters();
        a.jmp(e.first);
        a.bind(fail);
        a.retLocal();
    }

    /// Counts an iteration of the loop that the instruction at `pc`
    /// closes, toward the optimizing tier. When the counter reaches
    /// zero, the runtime looks for optimized code that starts at the
    /// first instruction of the loop, and the frame continues there.
    fn countLoop(e: *Emitter, pc: u32, target: u32) void {
        if (!e.count) return;
        const a = &e.a;
        a.movImm(A.t0, @intFromPtr(&e.p.opt_hot));
        a.load32(A.t1, .{ .base = A.t0 });
        a.addImmWord(A.t1, -1);
        a.store32(A.t1, .{ .base = A.t0 });
        a.jumpIfZero32(A.t1, true, e.addCold(pc, .{ .opt_loop = target }, 0));
    }

    /// `ret0` (n = 0) and `ret1` (n = 1) with the result in register
    /// `ra`. A lean frame without a to-be-closed variable returns here, as the lean
    /// return of the interpreter does, and continues in the caller at the
    /// address its call left in the frame. The caller's code after the
    /// call finishes what `interp.fast.finishLean` does. Any other frame
    /// takes the step routine.
    fn leanReturn(e: *Emitter, pc: u32, n: u32, ra: u32) void {
        e.leanReturnOr(n, ra, e.coldStep(pc));
    }

    /// The lean return, which branches to `slow` for a frame that needs
    /// the general return.
    pub fn leanReturnOr(e: *Emitter, n: u32, ra: u32, slow: Label) void {
        const a = &e.a;
        const lay = e.lay;
        const thread: A.Reg = A.thread;
        // t1 = the end of the running frame.
        a.loadWord(A.t0, .{ .base = thread, .disp = lay.frames_len });
        a.loadWord(A.t1, .{ .base = thread, .disp = lay.frames_ptr });
        a.addScaled(A.t1, A.t1, A.t0, frame_shift);
        a.jumpIfByte(.eq, .{ .base = A.t1, .disp = frameField("lean") - frame_size }, 0, slow);
        a.jumpIfByte(.ne, .{ .base = thread, .disp = @offsetOf(Thread, "hook_mask") }, 0, slow);
        // The open upvalues of this frame close in a call that returns
        // here. A to-be-closed variable of this frame needs the general
        // return.
        if (e.captures) {
            const none = a.newLabel();
            a.loadWord(A.t2, .{ .base = thread, .disp = @offsetOf(Thread, "open_upvals") });
            a.jumpIfImm(.eq, A.t2, 0, none);
            a.load32(A.t2, .{ .base = A.t2, .disp = @offsetOf(object.Upvalue, "level") });
            a.jumpIf(.lo, A.t2, A.base, none);
            a.mov(A.args[1], A.base);
            a.mov(A.args[0], thread);
            a.call(@intFromPtr(&helpers.closeUpvals));
            a.loadWord(A.t0, .{ .base = thread, .disp = lay.frames_len });
            a.loadWord(A.t1, .{ .base = thread, .disp = lay.frames_ptr });
            a.addScaled(A.t1, A.t1, A.t0, frame_shift);
            a.bind(none);
        }
        if (e.closes) {
            const none = a.newLabel();
            a.loadWord(A.t2, .{ .base = thread, .disp = lay.tbc_len });
            a.jumpIfImm(.eq, A.t2, 0, none);
            a.loadWord(A.t3, .{ .base = thread, .disp = lay.tbc_ptr });
            a.addScaled(A.t3, A.t3, A.t2, 2);
            a.load32(A.t2, .{ .base = A.t3, .disp = -4 });
            a.jumpIf(.hs, A.t2, A.base, slow);
            a.bind(none);
        }
        // The result goes to the slot of the called function, which is
        // the one below register 0.
        if (n == 1) a.copy16(.{ .base = A.bp, .disp = -16 }, slot(ra));
        // Pop the frame and continue in the caller, which adjusts the
        // result count.
        a.addImmWord(A.t0, -1);
        a.storeWord(A.t0, .{ .base = thread, .disp = lay.frames_len });
        a.load32(A.base, .{ .base = A.t1, .disp = frameField("base") - 2 * frame_size });
        a.loadWord(A.t3, .{ .base = A.t1, .disp = frameField("resume_at") - frame_size });
        a.movImm(A.t6, n);
        e.reloadBp();
        a.jmpReg(A.t3);
    }

    /// t0 = address of the value of upvalue `i` of the running closure,
    /// and `uv` = the upvalue object.
    fn loadUpvalLoc(e: *Emitter, dst: A.Reg, uv: A.Reg, i: u32) void {
        const a = &e.a;
        // The closure is the value below register 0.
        a.load64(uv, .{ .base = A.bp, .disp = -16 });
        a.loadWord(uv, .{ .base = uv, .disp = @intCast(@sizeOf(object.Closure) + i * @sizeOf(usize)) });
        a.loadWord(dst, .{ .base = uv, .disp = e.lay.upval_loc });
    }

    /// Passes the address of a value as argument `n`.
    fn passPlace(e: *Emitter, n: usize, pl: Place) void {
        const a = &e.a;
        switch (pl) {
            .reg => |r| a.lea(A.args[n], slot(r)),
            .konst => |k| a.movImm(A.args[n], @intFromPtr(&e.p.constants[k])),
            .upval => |i| e.loadUpvalLoc(A.args[n], A.args[n], i),
        }
    }

    // -----------------------------------------------------------------
    // Table accesses
    //
    // The inline paths below are the hit paths of `interp.fast`: a slot
    // prediction that names the right node, and an integer key inside
    // the array part. They read the layout of a table through
    // `table.layout` and of an inline cache through `interp.layout`.
    // Every other case calls the helper that runs the whole fast path
    // of the interpreter, and then the step routine.

    /// t0 = the table at `t`. Branches to `miss` when the value there is
    /// something else.
    fn loadTable(e: *Emitter, t: Place, miss: Label) void {
        const a = &e.a;
        switch (t) {
            .reg => |r| {
                a.jumpIfByte(.ne, tagOf(r), tag_table, miss);
                a.load64(A.t0, slot(r));
            },
            .upval => |i| {
                e.loadUpvalLoc(A.t0, A.t1, i);
                a.jumpIfByte(.ne, .{ .base = A.t0, .disp = tl.value_tag }, tag_table, miss);
                a.load64(A.t0, .{ .base = A.t0 });
            },
            .konst => unreachable,
        }
    }

    /// node = the hash node of the table in `tab` that the slot
    /// prediction at `slot_addr` names, and tags = the address from which
    /// its tags are at `tl.tag_key` and `tl.tag_val`. Branches to
    /// `out_of_range` when the table has no such node, and to `other_key`
    /// when the node holds another key than the string `key`, with both
    /// addresses computed. This is the test that `interp.lookupIc` makes
    /// before it trusts a prediction.
    fn predictedNode(e: *Emitter, slot_addr: usize, tab: A.Reg, key: *object.String, node: A.Reg, tags: A.Reg, tmp: A.Reg, out_of_range: Label, other_key: Label) void {
        const a = &e.a;
        a.movImm(node, slot_addr);
        a.load16(node, .{ .base = node });
        // The length is 32 bits wide.
        a.load32(tmp, .{ .base = tab, .disp = e.lay.hash_len });
        a.jumpIf(.hs, node, tmp, out_of_range);
        a.loadWord(tmp, .{ .base = tab, .disp = e.lay.hash_ptr });
        a.subScaled(tags, tmp, node, tl.tag_shift);
        a.addScaled(node, tmp, node, tl.node_shift);
        a.movImm(tmp, @intFromPtr(key));
        a.jumpIfMem(.ne, tmp, .{ .base = node, .disp = tl.node_key }, other_key);
        a.jumpIfByte(.ne, .{ .base = tags, .disp = tl.tag_key }, tag_string, other_key);
    }

    /// R[dst] = R[tr][R[kr]] for a table in `tr` and a string in `kr`,
    /// by probing the hash part inline as `table.findStr` does, when the
    /// key is interned and the part has room. It continues at `done` with
    /// the value, or with nil for an absent key of a table whose
    /// metatable lacks `__index`, and falls through to the helper for
    /// everything else.
    fn probeStr(e: *Emitter, tr: u32, kr: u32, dst: u32, done: Label) void {
        const a = &e.a;
        const call = a.newLabel();
        const loop = a.newLabel();
        const next = a.newLabel();
        const same = a.newLabel();
        const absent = a.newLabel();
        const nil_result = a.newLabel();
        a.load64(A.t0, slot(tr));
        a.load64(A.t6, slot(kr));
        a.jumpIfBit(.{ .base = A.t6, .disp = string_flags }, string_interned_bit, false, call);
        // A full part has no empty node to end the probe.
        a.load32(A.t2, .{ .base = A.t0, .disp = e.lay.hash_len });
        a.load32(A.t1, .{ .base = A.t0, .disp = tl.hash_used });
        a.jumpIf(.hs, A.t1, A.t2, call);
        a.addImm(A.t2, -1);
        a.loadWord(A.t3, .{ .base = A.t0, .disp = e.lay.hash_ptr });
        a.load32(A.t1, .{ .base = A.t6, .disp = @offsetOf(object.String, "hash") });
        a.bind(loop);
        a.@"and"(A.t1, A.t2);
        e.nodeTags(A.t4, A.t3, A.t1);
        a.jumpIfByte(.eq, .{ .base = A.t4, .disp = tl.tag_key }, tag_nil, absent);
        a.addScaled(A.t5, A.t3, A.t1, tl.node_shift);
        a.jumpIfMem(.eq, A.t6, .{ .base = A.t5, .disp = tl.node_key }, same);
        a.bind(next);
        a.addImm(A.t1, 1);
        a.jmp(loop);
        a.bind(same);
        a.jumpIfByte(.ne, .{ .base = A.t4, .disp = tl.tag_key }, tag_string, next);
        a.jumpIfByte(.eq, .{ .base = A.t4, .disp = tl.tag_val }, tag_nil, absent);
        e.loadNodeVal(slot(dst), A.t5, A.t4, A.t2, A.t3);
        a.jmp(done);
        // Absent, or present with nil: nil unless `__index` may apply.
        a.bind(absent);
        a.loadWord(A.t1, .{ .base = A.t0, .disp = tl.metatable });
        a.jumpIfImm(.eq, A.t1, 0, nil_result);
        a.jumpIfBit(.{ .base = A.t1, .disp = tl.tm_absent + il.absentByte(il.absent_index) }, il.absent_index % 8, false, call);
        a.bind(nil_result);
        e.storeConst(dst, .nil);
        a.jmp(done);
        a.bind(call);
    }

    /// R[tr][R[kr]] = R[vr] for a table in `tr` and a string in `kr` that
    /// the table already holds as a key, live or dead, by probing the
    /// hash part inline as `table.storeStr` does. The store must be raw
    /// and the key interned, and the part must have room. A new key, and
    /// everything else, falls through to the helper.
    fn probeStoreStr(e: *Emitter, tr: u32, kr: u32, vr: u32, done: Label) void {
        const a = &e.a;
        const call = a.newLabel();
        const loop = a.newLabel();
        const next = a.newLabel();
        const same = a.newLabel();
        a.load64(A.t0, slot(tr));
        e.guardRawStore(A.t0, A.t1, call);
        a.load64(A.t6, slot(kr));
        a.jumpIfBit(.{ .base = A.t6, .disp = string_flags }, string_interned_bit, false, call);
        a.load32(A.t2, .{ .base = A.t0, .disp = e.lay.hash_len });
        a.load32(A.t1, .{ .base = A.t0, .disp = tl.hash_used });
        a.jumpIf(.hs, A.t1, A.t2, call);
        a.addImm(A.t2, -1);
        a.loadWord(A.t3, .{ .base = A.t0, .disp = e.lay.hash_ptr });
        a.load32(A.t1, .{ .base = A.t6, .disp = @offsetOf(object.String, "hash") });
        a.bind(loop);
        a.@"and"(A.t1, A.t2);
        e.nodeTags(A.t4, A.t3, A.t1);
        a.jumpIfByte(.eq, .{ .base = A.t4, .disp = tl.tag_key }, tag_nil, call);
        a.addScaled(A.t5, A.t3, A.t1, tl.node_shift);
        a.jumpIfMem(.eq, A.t6, .{ .base = A.t5, .disp = tl.node_key }, same);
        a.bind(next);
        a.addImm(A.t1, 1);
        a.jmp(loop);
        a.bind(same);
        a.jumpIfByte(.ne, .{ .base = A.t4, .disp = tl.tag_key }, tag_string, next);
        e.storeNodeVal(slot(vr), A.t5, A.t4, A.t2);
        a.storeImm16(.{ .base = A.t0, .disp = tl.tm_absent }, 0);
        // The barrier: a collectable value stored into a black table.
        a.load8(A.t2, tagOf(vr));
        a.jumpIfImm(.lo, A.t2, tag_string, done);
        a.jumpIfBit(.{ .base = A.t0, .disp = tl.flags }, tl.barrier_bit, false, done);
        a.mov(A.args[1], A.t0);
        a.movImm(A.args[2], 0);
        a.lea(A.args[3], slot(vr));
        a.mov(A.args[0], A.thread);
        a.call(@intFromPtr(&helpers.barrierTable));
        a.jmp(done);
        a.bind(call);
    }

    /// The value of the node at `node`, whose tags are at `tags`, to the
    /// value at `dst`, through `tmp` and `tmp2`.
    fn loadNodeVal(e: *Emitter, dst: Mem, node: A.Reg, tags: A.Reg, tmp: A.Reg, tmp2: A.Reg) void {
        const a = &e.a;
        a.load64(tmp, .{ .base = node, .disp = tl.node_val });
        a.load8(tmp2, .{ .base = tags, .disp = tl.tag_val });
        a.storeValue(tmp, tmp2, dst);
    }

    /// The value at `src` to the node at `node`, whose tags are at
    /// `tags`, through `tmp`.
    fn storeNodeVal(e: *Emitter, src: Mem, node: A.Reg, tags: A.Reg, tmp: A.Reg) void {
        const a = &e.a;
        a.load64(tmp, src);
        a.store64(tmp, .{ .base = node, .disp = tl.node_val });
        a.load8(tmp, .{ .base = src.base, .disp = src.disp + tl.value_tag });
        a.store8(tmp, .{ .base = tags, .disp = tl.tag_val });
    }

    /// tags = the address from which the tags of node `index` of the hash
    /// part at `hp` are at `tl.tag_key` and `tl.tag_val`.
    fn nodeTags(e: *Emitter, tags: A.Reg, hp: A.Reg, index: A.Reg) void {
        e.a.subScaled(tags, hp, index, tl.tag_shift);
    }

    /// Address of a slot prediction of the instruction at `pc`.
    fn prediction(e: *Emitter, pc: u32, comptime offset: usize) usize {
        return @intFromPtr(&e.p.ic[pc]) + offset;
    }

    /// Branches to `miss` unless a store into the table in `tab` is a raw
    /// store: the table is writable and has no metatable, or one known to
    /// lack `__newindex`.
    fn guardRawStore(e: *Emitter, tab: A.Reg, tmp: A.Reg, miss: Label) void {
        const a = &e.a;
        const plain = a.newLabel();
        a.jumpIfByte(.ne, .{ .base = tab, .disp = tl.readonly }, 0, miss);
        a.loadWord(tmp, .{ .base = tab, .disp = tl.metatable });
        a.jumpIfImm(.eq, tmp, 0, plain);
        a.jumpIfBit(.{ .base = tmp, .disp = tl.tm_absent + il.absentByte(il.absent_newindex) }, il.absent_newindex % 8, false, miss);
        a.bind(plain);
    }

    /// The write barrier after a store of register `v` into the table in
    /// t0: nothing for a value that is not collectable, and otherwise the
    /// test of the barrier bit, with the slow part out of line.
    fn tableBarrier(e: *Emitter, pc: u32, v: u32, done: Label) void {
        const a = &e.a;
        a.load8(A.t2, tagOf(v));
        a.jumpIfImm(.lo, A.t2, tag_string, done);
        a.jumpIfBit(.{ .base = A.t0, .disp = tl.flags }, tl.barrier_bit, true, e.addCold(pc, .{ .barrier_table = .{ .v = v, .key = null } }, done));
    }

    /// The test that `interp.fast.getStr` makes of a shaped table before
    /// it trusts a slot prediction: the table in `tab` has the shape that
    /// the inline cache of `pc` names. Branches to `other` when it does
    /// not. Otherwise `slot` holds the address of the payload of the
    /// predicted slot, and its tag is at `tl.slot_tag` from `tags`. The
    /// key is a constant, so the shape alone proves that the slot holds
    /// it. A cache that recorded the shape without a slot proves that the
    /// table lacks the key, and the test branches to `absent`.
    fn shapedSlot(e: *Emitter, pc: u32, tab: A.Reg, slot_r: A.Reg, tags: A.Reg, tmp: A.Reg, other: Label, absent: Label) void {
        const a = &e.a;
        a.load32(tmp, .{ .base = tab, .disp = tl.hash_used });
        a.movImm(slot_r, e.prediction(pc, il.ic_shape));
        a.load16(slot_r, .{ .base = slot_r });
        a.movImmReloc(tags, tl.shaped_bit, .literal);
        a.@"or"(slot_r, tags);
        a.jumpIf(.ne, tmp, slot_r, other);
        a.movImm(slot_r, e.prediction(pc, il.ic_own));
        a.load16(slot_r, .{ .base = slot_r });
        // The cache records that the shape lacks the key.
        a.movImm(tags, object.IcEntry.none);
        a.jumpIf(.eq, slot_r, tags, absent);
        a.loadWord(tmp, .{ .base = tab, .disp = e.lay.hash_ptr });
        a.subScaled(tags, tmp, slot_r, 0);
        a.addScaled(slot_r, tmp, slot_r, tl.word_shift);
    }

    /// R[dst] = t[K[kc]] for a constant string key.
    fn fieldGet(e: *Emitter, pc: u32, t: Place, kc: u32, dst: u32) void {
        const a = &e.a;
        const done = a.newLabel();
        const dict = a.newLabel();
        const miss = e.addCold(pc, .{ .table = .{ .helper = @intFromPtr(&helpers.getStr), .t = t, .key = .{ .konst = kc }, .v = .{ .reg = dst } } }, done);
        e.loadTable(t, miss);
        e.shapedSlot(pc, A.t0, A.t1, A.t2, A.t3, dict, miss);
        // A nil value may have an `__index` to follow.
        a.jumpIfByte(.eq, .{ .base = A.t2, .disp = tl.slot_tag }, tag_nil, miss);
        a.load64(A.t3, .{ .base = A.t1 });
        a.load8(A.t4, .{ .base = A.t2, .disp = tl.slot_tag });
        a.storeValue(A.t3, A.t4, slot(dst));
        a.jmp(done);
        a.bind(dict);
        e.predictedNode(e.prediction(pc, il.ic_own), A.t0, e.p.constants[kc].as(object.String), A.t1, A.t2, A.t3, miss, miss);
        a.jumpIfByte(.eq, .{ .base = A.t2, .disp = tl.tag_val }, tag_nil, miss);
        e.loadNodeVal(slot(dst), A.t1, A.t2, A.t3, A.t4);
        a.bind(done);
    }

    /// t[K[kb]] = R[v] for a constant string key.
    fn fieldSet(e: *Emitter, pc: u32, t: Place, kb: u32, v: u32) void {
        const a = &e.a;
        const done = a.newLabel();
        const call: TableCall = .{ .helper = @intFromPtr(&helpers.setStr), .t = t, .key = .{ .konst = kb }, .v = .{ .reg = v } };
        const miss = e.addCold(pc, .{ .table = call }, done);
        const key = e.p.constants[kb].as(object.String);
        // A constructor stores into a fresh table, where the predicted
        // node is still empty.
        const other_key = if (key.flags().interned) e.addCold(pc, .{ .field_insert = call }, done) else miss;
        const dict = a.newLabel();
        const stored = a.newLabel();
        e.loadTable(t, miss);
        e.guardRawStore(A.t0, A.t1, miss);
        e.shapedSlot(pc, A.t0, A.t1, A.t2, A.t3, dict, miss);
        a.load64(A.t3, slot(v));
        a.store64(A.t3, .{ .base = A.t1 });
        a.load8(A.t3, tagOf(v));
        a.store8(A.t3, .{ .base = A.t2, .disp = tl.slot_tag });
        a.jmp(stored);
        // The store that the cache saw adding the key to a table of the
        // shape `ic.index`: the table moves to the shape `ic.holder`, and
        // the value goes into the slot `ic.own`, when its slots have room
        // for it (`interp.fast.setStr`).
        a.bind(dict);
        const dict2 = a.newLabel();
        a.load32(A.t3, .{ .base = A.t0, .disp = tl.hash_used });
        a.movImm(A.t1, e.prediction(pc, il.ic_index));
        a.load16(A.t1, .{ .base = A.t1 });
        a.movImmReloc(A.t2, tl.shaped_bit, .literal);
        a.@"or"(A.t1, A.t2);
        a.jumpIf(.ne, A.t3, A.t1, dict2);
        a.jumpIfByte(.eq, tagOf(v), tag_nil, miss);
        a.movImm(A.t1, e.prediction(pc, il.ic_own));
        a.load16(A.t1, .{ .base = A.t1 });
        a.loadWord(A.t3, .{ .base = A.t0, .disp = e.lay.hash_ptr });
        a.load8(A.t2, .{ .base = A.t3, .disp = -1 });
        a.jumpIf(.hs, A.t1, A.t2, miss);
        a.movImm(A.t2, e.prediction(pc, il.ic_holder));
        a.load16(A.t2, .{ .base = A.t2 });
        a.movImmReloc(A.t4, tl.shaped_bit, .literal);
        a.@"or"(A.t2, A.t4);
        a.store32(A.t2, .{ .base = A.t0, .disp = tl.hash_used });
        a.subScaled(A.t2, A.t3, A.t1, 0);
        a.addScaled(A.t1, A.t3, A.t1, tl.word_shift);
        a.load64(A.t3, slot(v));
        a.store64(A.t3, .{ .base = A.t1 });
        a.load8(A.t3, tagOf(v));
        a.store8(A.t3, .{ .base = A.t2, .disp = tl.slot_tag });
        a.jmp(stored);
        a.bind(dict2);
        e.predictedNode(e.prediction(pc, il.ic_own), A.t0, key, A.t1, A.t2, A.t3, miss, other_key);
        e.storeNodeVal(slot(v), A.t1, A.t2, A.t3);
        a.bind(stored);
        a.storeImm16(.{ .base = A.t0, .disp = tl.tm_absent }, 0);
        e.tableBarrier(pc, v, done);
        a.bind(done);
    }

    /// R[ra + 1] = R[rb] and R[ra] = R[rb][K[kc]], the lookup of a
    /// method. The receiver itself holds the method, or the table that
    /// `__index` of its metatable names does.
    fn method(e: *Emitter, pc: u32, ra: u32, rb: u32, kc: u32) void {
        const a = &e.a;
        const done = a.newLabel();
        const chain = a.newLabel();
        const call: TableCall = .{ .helper = @intFromPtr(&helpers.getStr), .t = .{ .reg = ra + 1 }, .key = .{ .konst = kc }, .v = .{ .reg = ra } };
        const other = e.addCold(pc, .{ .method = .{ .call = call, .chain = chain, .rb = rb } }, done);
        const miss = e.addCold(pc, .{ .table = call }, done);
        const dict = a.newLabel();
        a.copy16(slot(ra + 1), slot(rb));
        a.jumpIfByte(.ne, tagOf(rb), tag_table, other);
        a.load64(A.t0, slot(rb));
        // A shaped receiver that holds the method in its predicted slot,
        // or whose shape the cache knows to lack it, which sends it to
        // the chain: it has no hash nodes, so the chain goes straight to
        // the metatable. A shaped receiver of another shape takes the
        // helper, since the chain proves only that a dictionary lacks
        // the key.
        e.shapedSlot(pc, A.t0, A.t1, A.t2, A.t3, dict, chain);
        a.jumpIfByte(.eq, .{ .base = A.t2, .disp = tl.slot_tag }, tag_nil, miss);
        a.load64(A.t3, .{ .base = A.t1 });
        a.load8(A.t4, .{ .base = A.t2, .disp = tl.slot_tag });
        a.storeValue(A.t3, A.t4, slot(ra));
        a.jmp(done);
        a.bind(dict);
        a.load32(A.t1, .{ .base = A.t0, .disp = tl.hash_used });
        a.movImmReloc(A.t2, tl.shaped_bit, .literal);
        a.jumpIf(.hs, A.t1, A.t2, miss);
        e.predictedNode(e.prediction(pc, il.ic_own), A.t0, e.p.constants[kc].as(object.String), A.t1, A.t2, A.t3, chain, chain);
        a.jumpIfByte(.eq, .{ .base = A.t2, .disp = tl.tag_val }, tag_nil, miss);
        e.loadNodeVal(slot(ra), A.t1, A.t2, A.t3, A.t4);
        a.bind(done);
    }

    /// R[dst] = the array slot t1 (zero-based) of the table in t0.
    /// Branches to `outside` for an index outside the array part, and to
    /// `miss` for a slot that holds nil, which may have an `__index` to
    /// follow.
    fn arrayGet(e: *Emitter, dst: u32, outside: Label, miss: Label, done: Label) void {
        const a = &e.a;
        const boxed = a.newLabel();
        // An index below one wrapped around to a large unsigned number.
        a.load32(A.t2, .{ .base = A.t0, .disp = tl.asize });
        a.jumpIf(.hs, A.t1, A.t2, outside);
        a.loadWord(A.t2, .{ .base = A.t0, .disp = tl.array_ptr });
        a.load8(A.t3, .{ .base = A.t0, .disp = tl.kind });
        a.jumpIfImm(.eq, A.t3, tl.kind_boxed, boxed);
        // An unboxed slot is the payload, and the kind is its tag. A part
        // of kind `none` holds only the nil word.
        a.addScaled(A.t2, A.t2, A.t1, tl.word_shift);
        a.load64(A.t4, .{ .base = A.t2 });
        a.movImm(A.t5, tl.nil_word);
        a.jumpIf(.eq, A.t4, A.t5, miss);
        a.store64(A.t4, slot(dst));
        a.storeTag(A.t3, tagOf(dst));
        a.jmp(done);
        a.bind(boxed);
        a.addScaled(A.t2, A.t2, A.t1, tl.value_shift);
        a.jumpIfByte(.eq, .{ .base = A.t2, .disp = tl.value_tag }, tag_nil, miss);
        a.copy16(slot(dst), .{ .base = A.t2 });
    }

    /// Stores R[v] into the array slot t1 (zero-based) of the table in
    /// t0, as `table.arrayStoreFast` does when the value fits the kind of
    /// the array part. Branches to `outside` for an index outside the
    /// array part, and to `miss` for a table that is not plain and for a
    /// value of another kind.
    fn arraySet(e: *Emitter, pc: u32, v: u32, outside: Label, miss: Label, done: Label) void {
        const a = &e.a;
        const boxed = a.newLabel();
        a.load32(A.t2, .{ .base = A.t0, .disp = tl.asize });
        a.jumpIf(.hs, A.t1, A.t2, outside);
        e.guardRawStore(A.t0, A.t2, miss);
        a.loadWord(A.t2, .{ .base = A.t0, .disp = tl.array_ptr });
        a.load8(A.t3, .{ .base = A.t0, .disp = tl.kind });
        a.load8(A.t4, tagOf(v));
        a.jumpIfImm(.eq, A.t3, tl.kind_boxed, boxed);
        // An unboxed part takes a value of its own kind whose
        // bits are not the nil word. Anything else changes the part or
        // writes the nil word, which the helper does.
        a.jumpIf(.ne, A.t3, A.t4, miss);
        a.jumpIfImm(.eq, A.t3, tl.kind_none, miss);
        a.load64(A.t5, slot(v));
        a.movImm(A.t6, tl.nil_word);
        a.jumpIf(.eq, A.t5, A.t6, miss);
        a.addScaled(A.t2, A.t2, A.t1, tl.word_shift);
        a.store64(A.t5, .{ .base = A.t2 });
        // Parts of kind `string` and `table` hold collectable values, and
        // their kinds, which equal the tags of their values, are the ones
        // at or above the tag of strings. Numbers leave by the one branch
        // they took before.
        a.jumpIfImm(.lo, A.t3, tag_string, done);
        a.jumpIfBit(.{ .base = A.t0, .disp = tl.flags }, tl.barrier_bit, true, e.addCold(pc, .{ .barrier_table = .{ .v = v, .key = null } }, done));
        a.jmp(done);
        a.bind(boxed);
        a.addScaled(A.t2, A.t2, A.t1, tl.value_shift);
        a.copy16(.{ .base = A.t2 }, slot(v));
        e.tableBarrier(pc, v, done);
    }

    /// Calls a fast-path helper that takes the thread, the table, the
    /// key, the inline cache, and the value or result, and continues at
    /// `resume_at` when it completed the instruction. Otherwise the step
    /// routine runs.
    fn tableHelper(e: *Emitter, pc: u32, c: TableCall, resume_at: Label) void {
        const a = &e.a;
        e.tableCall(pc, c.helper, c.t, c.key, c.v);
        a.jumpIfImm(.eq, A.ret0, 0, resume_at);
        e.step(pc, false);
    }

    fn tableCall(e: *Emitter, pc: u32, helper: usize, t: Place, key: Place, v: Place) void {
        const a = &e.a;
        a.mov(A.args[0], A.thread);
        e.passPlace(1, t);
        e.passPlace(2, key);
        a.movImm(A.args[3], @intFromPtr(&e.p.ic[pc]));
        e.passPlace(4, v);
        a.call5(helper);
    }

    /// R[dst] = x op y. Integer operands run inline, float operands out
    /// of line, and everything else in the step routine. A float constant
    /// swaps the two paths.
    fn arith(e: *Emitter, pc: u32, op: ArithOp, dst: u32, x: Operand, y: Operand) void {
        const a = &e.a;
        const done = a.newLabel();
        const float_first = y == .float or op == .div;
        const ar: Arith = .{ .op = op, .dst = dst, .x = x, .y = y, .ints = op == .div and y != .float };
        if (float_first) {
            // Division always yields a float, so its float operands take
            // the main path and integers convert out of line.
            const other = if (ar.ints) e.addCold(pc, .{ .arith_float = ar }, done) else e.coldStep(pc);
            e.guard(x, tag_float, other);
            e.guard(y, tag_float, other);
            e.floatArith(ar, false);
        } else {
            const other = e.addCold(pc, .{ .arith_float = ar }, done);
            e.guard(x, tag_int, other);
            e.guard(y, tag_int, other);
            e.loadInt(A.t0, x);
            e.loadInt(A.t1, y);
            switch (op) {
                .add => a.add(A.t0, A.t1),
                .sub => a.sub(A.t0, A.t1),
                .mul => a.mul(A.t0, A.t1),
                .div => unreachable,
            }
            a.store64(A.t0, slot(dst));
            e.storeTag(dst, tag_int);
        }
        a.bind(done);
    }

    /// Loads both operands as floats, converting integers when
    /// `from_ints` is set, and stores the float result.
    fn floatArith(e: *Emitter, ar: Arith, from_ints: bool) void {
        const a = &e.a;
        if (from_ints) {
            e.loadInt(A.t0, ar.x);
            a.intToFloat(A.f0, A.t0);
            e.loadInt(A.t0, ar.y);
            a.intToFloat(A.f1, A.t0);
        } else {
            e.loadFloat(A.f0, ar.x);
            e.loadFloat(A.f1, ar.y);
        }
        switch (ar.op) {
            .add => a.fadd(A.f0, A.f1),
            .sub => a.fsub(A.f0, A.f1),
            .mul => a.fmul(A.f0, A.f1),
            .div => a.fdiv(A.f0, A.f1),
        }
        a.storeF(A.f0, slot(ar.dst));
        e.storeTag(ar.dst, tag_float);
    }

    /// R[dst] = R[x] % y or R[x] // y for integers, with the rounding
    /// toward minus infinity of `ops.imod` and `ops.idiv`. A divisor of
    /// zero or minus one takes the step routine, which raises the error
    /// or avoids the overflow.
    fn divide(e: *Emitter, pc: u32, mod: bool, dst: u32, x: u32, y: Operand) void {
        const a = &e.a;
        const done = a.newLabel();
        const slow = e.coldStep(pc);
        a.jumpIfByte(.ne, tagOf(x), tag_int, slow);
        e.guard(y, tag_int, slow);
        a.load64(A.t3, slot(x));
        e.loadInt(A.t4, y);
        if (y == .reg) {
            a.jumpIfImm(.eq, A.t4, 0, slow);
            a.jumpIfImm(.eq, A.t4, -1, slow);
        }
        // t5 = quotient, t1 = remainder, both truncated toward zero.
        a.divRem(A.t5, A.t1, A.t3, A.t4);
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        a.jumpIfImm(.eq, A.t1, 0, done);
        a.mov(A.t3, A.t1);
        a.xor(A.t3, A.t4);
        a.jumpIfImm(.ge, A.t3, 0, done);
        if (mod) a.add(A.t1, A.t4) else a.addImm(A.t5, -1);
        a.bind(done);
        a.store64(if (mod) A.t1 else A.t5, slot(dst));
        e.storeTag(dst, tag_int);
    }

    /// Whether the instruction after `pc` is the jump that every test
    /// instruction is followed by.
    fn jumpFollows(e: *Emitter, pc: u32) bool {
        return pc + 1 < e.p.code.len and opc.op(e.p.code[pc + 1]) == .jmp;
    }

    /// A comparison that skips the following jump when its result equals
    /// `skip_when`, and otherwise falls into that jump.
    fn compare(e: *Emitter, pc: u32, op: CompareOp, x: Operand, y: Operand, k: bool) void {
        const a = &e.a;
        if (!e.jumpFollows(pc)) return e.step(pc, true);
        // The instruction skips when the result differs from k.
        const cmp: Compare = .{ .op = op, .x = x, .y = y, .skip_when = !k };
        const skip = e.at(pc + 2);
        const other = if (op == .eq) e.coldStep(pc) else e.addCold(pc, .{ .compare_float = cmp }, e.at(pc + 1));
        e.guard(x, tag_int, other);
        e.guard(y, tag_int, other);
        e.loadInt(A.t0, x);
        e.loadInt(A.t1, y);
        const holds: A.Cond = switch (op) {
            .lt => .lt,
            .le => .le,
            .eq => .eq,
        };
        a.jumpIf(if (cmp.skip_when) holds else holds.invert(), A.t0, A.t1, skip);
    }

    /// R[x] == K, for the constants whose equality the tag and the
    /// payload decide.
    fn equalConstant(e: *Emitter, pc: u32, x: u32, k: Value, c: bool) void {
        const a = &e.a;
        if (!e.jumpFollows(pc)) return e.step(pc, true);
        const skip = e.at(pc + 2);
        switch (k.tag) {
            .integer => {
                // Another number type compares in the step routine.
                a.jumpIfByte(.ne, tagOf(x), tag_int, e.coldStep(pc));
                a.load64(A.t0, slot(x));
                a.movImmReloc(A.t1, k.payload, .literal);
                // Skip when the result differs from C.
                a.jumpIf(if (c) .ne else .eq, A.t0, A.t1, skip);
            },
            .nil, .false, .true => {
                a.load8(A.t0, tagOf(x));
                a.jumpIfImm(if (c) .ne else .eq, A.t0, @backingInt(k.tag), skip);
            },
            .string => {
                // Two interned strings are equal exactly when they are
                // the same object. The constant is interned, so an
                // operand that is another object can equal it only when
                // the operand is not interned, and the step routine
                // compares the bytes then.
                if (!k.as(object.String).flags().interned) return e.step(pc, true);
                const differ = if (c) skip else e.at(pc + 1);
                const same = if (c) e.at(pc + 1) else skip;
                a.jumpIfByte(.ne, tagOf(x), tag_string, differ);
                a.load64(A.t0, slot(x));
                a.movImm(A.t1, k.payload);
                a.jumpIf(.eq, A.t0, A.t1, same);
                a.jumpIfBit(.{ .base = A.t0, .disp = string_flags }, string_interned_bit, false, e.coldStep(pc));
                a.jmp(differ);
            },
            else => e.step(pc, true),
        }
    }

    // -----------------------------------------------------------------
    // Out-of-line code

    fn emitCold(e: *Emitter, c: Cold) void {
        const a = &e.a;
        a.bind(c.entry);
        e.cur_pc = c.pc;
        switch (c.kind) {
            .step => e.step(c.pc, false),
            .opt_loop => |target| {
                a.mov(A.args[0], A.thread);
                a.movImm(A.args[1], target);
                a.call(@intFromPtr(&jit.opt.loopEntry));
                a.jumpIfImm(.eq, A.ret0, 0, e.at(target));
                a.jmpReg(A.ret0);
            },
            .arith_float => |ar| {
                const slow = a.newLabel();
                if (ar.y == .float or ar.op == .div) {
                    // The main path wanted floats. Two integers convert.
                    e.guard(ar.x, tag_int, slow);
                    e.guard(ar.y, tag_int, slow);
                    e.floatArith(ar, true);
                } else {
                    e.guard(ar.x, tag_float, slow);
                    e.guard(ar.y, tag_float, slow);
                    e.floatArith(ar, false);
                }
                a.jmp(c.resume_at);
                a.bind(slow);
                e.step(c.pc, false);
            },
            .compare_float => |cmp| {
                const slow = a.newLabel();
                e.guard(cmp.x, tag_float, slow);
                e.guard(cmp.y, tag_float, slow);
                e.loadFloat(A.f0, cmp.x);
                e.loadFloat(A.f1, cmp.y);
                const cond: A.FCond = switch (cmp.op) {
                    .lt => if (cmp.skip_when) .lt else .nlt,
                    .le => if (cmp.skip_when) .le else .nle,
                    .eq => unreachable,
                };
                a.jumpIfFloat(cond, A.f0, A.f1, e.at(c.pc + 2));
                a.jmp(c.resume_at);
                a.bind(slow);
                e.step(c.pc, false);
            },
            .barrier => {
                a.mov(A.args[1], A.t1);
                a.mov(A.args[0], A.thread);
                a.call(@intFromPtr(&helpers.barrier));
                a.jmp(c.resume_at);
            },
            .native_call => {
                const other = a.newLabel();
                a.mov(A.args[0], A.thread);
                a.movImmReloc(A.args[1], e.p.code[c.pc], .literal);
                a.movImm(A.args[2], c.pc + 1);
                a.call(@intFromPtr(&helpers.callNative));
                a.jumpIfImm(.ne, A.ret0, 0, other);
                e.reloadBp();
                a.jmp(c.resume_at);
                a.bind(other);
                // Anything but a request for the step routine is a status.
                a.jumpIfImm(.ne, A.ret0, @intCast(helpers.retry), e.l_status);
                e.step(c.pc, false);
            },
            .barrier_table => |b| {
                a.mov(A.args[1], A.t0);
                if (b.key) |k| a.movImm(A.args[2], @intFromPtr(&e.p.constants[k])) else a.movImm(A.args[2], 0);
                a.lea(A.args[3], slot(b.v));
                a.mov(A.args[0], A.thread);
                a.call(@intFromPtr(&helpers.barrierTable));
                a.jmp(c.resume_at);
            },
            .tail_helper => {
                const ins = e.p.code[c.pc];
                a.mov(A.args[0], A.thread);
                a.mov(A.args[1], A.bp);
                a.movImmReloc(A.args[2], ins, .literal);
                a.movImm(A.args[3], c.pc + 1);
                a.callPair(@intFromPtr(&helpers.tailcall));
                const refused = a.newLabel();
                a.jumpIfImm(.eq, A.ret0, 0, refused);
                a.mov(A.base, A.ret1);
                e.reloadBp();
                a.jmpReg(A.ret0);
                a.bind(refused);
                e.step(c.pc, false);
            },
            .native_tail => {
                const other = a.newLabel();
                const general = a.newLabel();
                const ins = e.p.code[c.pc];
                const ra: u32 = opc.a(ins);
                a.mov(A.args[0], A.thread);
                a.movImmReloc(A.args[1], ins, .literal);
                a.movImm(A.args[2], c.pc + 1);
                a.call(@intFromPtr(&helpers.tailNative));
                a.jumpIfImm(.ne, A.ret0, 0, other);
                e.reloadBp();
                // One result from a lean frame returns here, and it is
                // in the register of the callee.
                a.load32(A.t0, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                a.sub(A.t0, A.base);
                a.jumpIfImm(.ne, A.t0, @intCast(ra + 1), general);
                e.leanReturnOr(1, ra, general);
                a.bind(general);
                a.mov(A.args[0], A.thread);
                if (@hasDecl(A.Assembler, "loadStop")) a.loadStop(A.args[1]) else a.mov(A.args[1], A.stop);
                a.movImmReloc(A.args[2], ins, .literal);
                a.call(@intFromPtr(&helpers.returnAll));
                a.jmp(e.l_status);
                a.bind(other);
                // Anything but a request for the step routine is a status.
                a.jumpIfImm(.ne, A.ret0, @intCast(helpers.retry), e.l_status);
                e.step(c.pc, false);
            },
            .table => |t| {
                if (t.key_tag) |tag| {
                    const slow = a.newLabel();
                    a.jumpIfByte(.ne, tagOf(t.key.reg), tag, slow);
                    if (t.helper == @intFromPtr(&helpers.getStr)) e.probeStr(t.t.reg, t.key.reg, t.v.reg, c.resume_at);
                    if (t.helper == @intFromPtr(&helpers.setStr)) e.probeStoreStr(t.t.reg, t.key.reg, t.v.reg, c.resume_at);
                    e.tableCall(c.pc, t.helper, t.t, t.key, t.v);
                    a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                    a.bind(slow);
                    e.step(c.pc, false);
                } else e.tableHelper(c.pc, t, c.resume_at);
            },
            .field_insert => |t| {
                // What `table.storeStr` does for an absent key: the
                // predicted node is empty, the probe of the key reaches
                // it over nodes that hold other keys, the value is not
                // nil, and the hash part has room.
                const helper = a.newLabel();
                const loop = a.newLabel();
                const reached = a.newLabel();
                const key = e.p.constants[t.key.konst];
                const s = key.as(object.String);
                const v = t.v.reg;
                // t1 and t2 hold the predicted node and its tags.
                a.jumpIfByte(.ne, .{ .base = A.t2, .disp = tl.tag_key }, tag_nil, helper);
                a.jumpIfByte(.eq, tagOf(v), tag_nil, helper);
                a.load32(A.t2, .{ .base = A.t0, .disp = e.lay.hash_len });
                a.addImm(A.t2, -1);
                a.loadWord(A.t4, .{ .base = A.t0, .disp = e.lay.hash_ptr });
                a.movImmReloc(A.t3, s.hash, .literal);
                a.movImm(A.t6, @intFromPtr(s));
                a.bind(loop);
                a.@"and"(A.t3, A.t2);
                a.addScaled(A.t5, A.t4, A.t3, tl.node_shift);
                a.jumpIf(.eq, A.t5, A.t1, reached);
                a.jumpIfMem(.eq, A.t6, .{ .base = A.t5, .disp = tl.node_key }, helper);
                e.nodeTags(A.t5, A.t4, A.t3);
                a.jumpIfByte(.eq, .{ .base = A.t5, .disp = tl.tag_key }, tag_nil, helper);
                a.addImm(A.t3, 1);
                a.jmp(loop);
                a.bind(reached);
                // t6 = the tags of the node the key goes into.
                e.nodeTags(A.t6, A.t4, A.t3);
                // Room: (used + 1) * 4 <= len * 3, where t2 = len - 1.
                a.load32(A.t3, .{ .base = A.t0, .disp = tl.hash_used });
                a.addImm(A.t3, 1);
                a.mov(A.t4, A.t3);
                a.add(A.t4, A.t4);
                a.add(A.t4, A.t4);
                a.addImm(A.t2, 1);
                a.mov(A.t5, A.t2);
                a.add(A.t5, A.t5);
                a.add(A.t5, A.t2);
                a.jumpIf(.hi, A.t4, A.t5, helper);
                a.store32(A.t3, .{ .base = A.t0, .disp = tl.hash_used });
                a.storeImm64(.{ .base = A.t1, .disp = tl.node_key }, @intFromPtr(s));
                a.movImm(A.t5, tag_string);
                a.store8(A.t5, .{ .base = A.t6, .disp = tl.tag_key });
                e.storeNodeVal(slot(v), A.t1, A.t6, A.t5);
                a.storeImm16(.{ .base = A.t0, .disp = tl.tm_absent }, 0);
                // The table now holds the key, so the barrier runs for
                // the key and the value whatever the value is.
                a.jumpIfBit(.{ .base = A.t0, .disp = tl.flags }, tl.barrier_bit, true, e.addCold(c.pc, .{ .barrier_table = .{ .v = v, .key = t.key.konst } }, c.resume_at));
                a.jmp(c.resume_at);
                a.bind(helper);
                e.tableHelper(c.pc, t, c.resume_at);
            },
            .method => |m| {
                const helper = a.newLabel();
                const in_metatable = a.newLabel();
                const have_metatable = a.newLabel();
                const s = e.p.constants[m.call.key.konst].as(object.String);
                const g = e.g;
                const dst = m.call.v.reg;
                // A string finds its methods through the metatable that
                // all strings share.
                a.jumpIfByte(.ne, tagOf(m.rb), tag_string, helper);
                a.movImm(A.t1, @intFromPtr(&g.type_metatables[value.typeSlot(.string)]));
                a.loadWord(A.t1, .{ .base = A.t1 });
                a.jmp(have_metatable);

                // The receiver is a table whose prediction missed. The
                // probe below is `table.findStr` for an interned key. It
                // proves that the key is absent, and a key that is
                // present goes to the helper, which records where. A
                // small hash part may be full, so the probe also ends
                // after visiting every node, counted down in t5.
                a.bind(m.chain);
                if (!s.flags().interned) {
                    a.jmp(helper);
                } else {
                    const loop = a.newLabel();
                    a.load32(A.t2, .{ .base = A.t0, .disp = e.lay.hash_len });
                    a.jumpIfImm(.eq, A.t2, 0, in_metatable);
                    a.mov(A.t5, A.t2);
                    a.addImm(A.t2, -1);
                    a.loadWord(A.t3, .{ .base = A.t0, .disp = e.lay.hash_ptr });
                    a.movImmReloc(A.t1, s.hash, .literal);
                    a.movImm(A.t6, @intFromPtr(s));
                    a.bind(loop);
                    a.@"and"(A.t1, A.t2);
                    e.nodeTags(A.t4, A.t3, A.t1);
                    a.jumpIfByte(.eq, .{ .base = A.t4, .disp = tl.tag_key }, tag_nil, in_metatable);
                    a.addScaled(A.t4, A.t3, A.t1, tl.node_shift);
                    a.jumpIfMem(.eq, A.t6, .{ .base = A.t4, .disp = tl.node_key }, helper);
                    a.addImm(A.t1, 1);
                    a.addImm(A.t5, -1);
                    a.jumpIfImm(.ne, A.t5, 0, loop);
                    a.jmp(in_metatable);
                }

                // The first step of `interp.indexChain`: `__index` of the
                // metatable names a table, and that table holds the key.
                a.bind(in_metatable);
                a.loadWord(A.t1, .{ .base = A.t0, .disp = tl.metatable });
                a.bind(have_metatable);
                a.jumpIfImm(.eq, A.t1, 0, helper);
                a.jumpIfBit(.{ .base = A.t1, .disp = tl.tm_absent + il.absentByte(il.absent_index) }, il.absent_index % 8, true, helper);
                e.predictedNode(e.prediction(c.pc, il.ic_index), A.t1, g.tm_names[@backingInt(state.TM.index)].?, A.t2, A.t4, A.t3, helper, helper);
                a.jumpIfByte(.ne, .{ .base = A.t4, .disp = tl.tag_val }, tag_table, helper);
                a.load64(A.t1, .{ .base = A.t2, .disp = tl.node_val });
                e.predictedNode(e.prediction(c.pc, il.ic_holder), A.t1, s, A.t2, A.t4, A.t3, helper, helper);
                a.jumpIfByte(.eq, .{ .base = A.t4, .disp = tl.tag_val }, tag_nil, helper);
                e.loadNodeVal(slot(dst), A.t2, A.t4, A.t3, A.t5);
                a.jmp(c.resume_at);
                a.bind(helper);
                e.tableHelper(c.pc, m.call, c.resume_at);
            },
            .get_array => |g| {
                a.load64(A.args[0], slot(g.t));
                a.load64(A.args[1], slot(g.key));
                a.lea(A.args[2], slot(g.dst));
                a.callWide(@intFromPtr(&helpers.getArray));
                a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                e.step(c.pc, false);
            },
            .set_array => |g| {
                a.mov(A.args[0], A.thread);
                a.load64(A.args[1], slot(g.t));
                a.load64(A.args[2], slot(g.key));
                a.lea(A.args[3], slot(g.v));
                a.callWide(@intFromPtr(&helpers.setArray));
                a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                e.step(c.pc, false);
            },
            .get_index => |g| {
                a.lea(A.args[0], slot(g.t));
                a.movImm(A.args[1], g.index);
                a.lea(A.args[2], slot(g.dst));
                a.call(@intFromPtr(&helpers.getIndex));
                a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                e.step(c.pc, false);
            },
            .length => |g| {
                a.lea(A.args[0], slot(g.x));
                a.lea(A.args[1], slot(g.dst));
                a.call(@intFromPtr(&helpers.length));
                a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                e.step(c.pc, false);
            },
        }
    }
};
