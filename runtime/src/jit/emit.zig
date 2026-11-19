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
const opc = @import("../compile/opcodes.zig");
const jit = @import("jit.zig");
const helpers = @import("helpers.zig");
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
    else => @compileError("the JIT has no backend for this target"),
};
const Mem = A.Mem;
const Label = A.Label;

const tag_int: u8 = @backingInt(Tag.integer);
const tag_float: u8 = @backingInt(Tag.float);
const tag_string: u8 = @backingInt(Tag.string);
const tag_table: u8 = @backingInt(Tag.table);
const tag_closure: u8 = @backingInt(Tag.closure);
const Frame = state.Frame;
const frame_size: i32 = @sizeOf(Frame);

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
    /// Address of the frame image that a native call copies.
    template: usize,

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
            .template = @intFromPtr(&g.jit.frame_template),
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
        /// A table access through a fast-path helper, for a key whose
        /// tag is `key_tag`.
        table: struct { helper: usize, t: Place, key: Place, v: Place, key_tag: u8 },
    };
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
    a: A.Assembler,
    gpa: std.mem.Allocator,
    p: *Proto,
    lay: Layout,
    cold: std.ArrayList(Cold) = .empty,
    /// Label of instruction 0. The label of instruction `pc` follows.
    first: Label = 0,
    l_status: Label = 0,
    l_dispatch: Label = 0,
    l_exit: Label = 0,
    oom: bool = false,
    l_ret: [2]Label = .{ 0, 0 },
    /// Offset of the code that a native call enters the function at, or
    /// zero when the function has none.
    call_entry: u32 = 0,
    /// The instruction that `step_label` runs the step routine of.
    step_pc: u32 = std.math.maxInt(u32),
    step_label: Label = 0,

    pub fn init(gpa: std.mem.Allocator, l: *Thread, p: *Proto) Emitter {
        return .{ .a = A.Assembler.init(gpa), .gpa = gpa, .p = p, .lay = Layout.of(l) };
    }

    pub fn deinit(e: *Emitter) void {
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

        e.l_status = a.newLabel();
        e.l_dispatch = a.newLabel();
        e.l_exit = a.newLabel();
        e.first = a.newLabels(code.len + 1);

        // A step returned something other than "next". Codes up to
        // "dispatch" continue at the saved pc of the top frame, and the
        // others leave native code.
        a.bind(e.l_status);
        a.jumpIfImm(.hi, A.ret0, @intCast(Step.dispatch), e.l_exit);
        a.bind(e.l_dispatch);
        a.mov(A.args[0], A.thread);
        a.call(@intFromPtr(&jit.dispatch));
        const l_interp = a.newLabel();
        a.jumpIfImm(.eq, A.ret0, 0, l_interp);
        a.mov(A.base, A.ret1);
        e.reloadBp();
        a.jmpReg(A.ret0);
        a.bind(l_interp);
        a.movImm(A.ret0, Step.interpret);
        a.bind(e.l_exit);
        a.epilogue();

        e.l_ret = .{ a.newLabel(), a.newLabel() };
        e.returnRoutine(0);
        e.returnRoutine(1);
        // The call entry runs into the first instruction.
        if (!e.p.is_vararg) e.callEntry();

        var pc: u32 = 0;
        while (pc < code.len) : (pc += 1) {
            a.bind(e.first + pc);
            e.instruction(pc, code[pc]);
        }
        // Execution never runs off the end of a function.
        a.bind(e.first + pc);
        a.trap();

        for (e.cold.items) |c| e.emitCold(c);

        if (e.oom or !a.finish()) return false;
        for (offs, 0..) |*o, i| o.* = a.labelOffset(e.first + @as(u32, @intCast(i)));
        return true;
    }

    // -----------------------------------------------------------------
    // Building blocks

    fn at(e: *const Emitter, pc: u32) Label {
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
    fn reloadBp(e: *Emitter) void {
        e.a.load64(A.bp, .{ .base = A.thread, .disp = e.lay.stack_ptr });
        e.a.addScaled(A.bp, A.bp, A.base, 4);
    }

    fn addCold(e: *Emitter, pc: u32, kind: Cold.Kind, resume_at: Label) Label {
        const entry = e.a.newLabel();
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
        a.mov(A.args[2], A.stop);
        a.movImm(A.args[3], e.p.code[pc]);
        a.call(@intFromPtr(helpers.steps[@backingInt(o)]));
        a.jumpIfImm(.hi, A.ret0, @intCast(Step.skip), e.l_status);
        e.reloadBp();
        a.jumpIfImm(.ne, A.ret0, 0, e.at(@min(pc + 2, @as(u32, @intCast(e.p.code.len)))));
        if (!fallthrough) a.jmp(e.at(pc + 1));
    }

    fn storeTag(e: *Emitter, r: u32, tag: u8) void {
        e.a.storeImm64(tagOf(r), tag);
    }

    /// Stores a constant value into a register.
    fn storeConst(e: *Emitter, r: u32, v: Value) void {
        const w: *const [2]u64 = @ptrCast(&v);
        e.a.storeImm64(slot(r), w[0]);
        e.a.storeImm64(tagOf(r), w[1]);
    }

    fn loadInt(e: *Emitter, dst: A.Reg, o: Operand) void {
        switch (o) {
            .reg => |r| e.a.load64(dst, slot(r)),
            .int => |v| e.a.movImm(dst, @bitCast(v)),
            .float => unreachable,
        }
    }

    /// Loads a float operand. An integer constant converts.
    fn loadFloat(e: *Emitter, dst: A.FReg, o: Operand) void {
        switch (o) {
            .reg => |r| e.a.loadF(dst, slot(r)),
            .int => |v| {
                e.a.movImm(A.t0, @bitCast(@as(f64, @floatFromInt(v))));
                e.a.bitsToFloat(dst, A.t0);
            },
            .float => |v| {
                e.a.movImm(A.t0, @bitCast(v));
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

    fn instruction(e: *Emitter, pc: u32, ins: u32) void {
        const a = &e.a;
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

            .getfield => e.tableOp(pc, &helpers.getStr, .{ .reg = rb }, .{ .konst = rc }, .{ .reg = ra }),
            .setfield => e.tableOp(pc, &helpers.setStr, .{ .reg = ra }, .{ .konst = rb }, .{ .reg = rc }),
            .gettabup => e.tableOp(pc, &helpers.getStr, .{ .upval = rb }, .{ .konst = rc }, .{ .reg = ra }),
            .settabup => e.tableOp(pc, &helpers.setStr, .{ .upval = ra }, .{ .konst = rb }, .{ .reg = rc }),
            .gettable => {
                // An integer key reads the array part. A string key takes
                // the inline cache out of line.
                const done = a.newLabel();
                const by_name: Cold.Kind = .{ .table = .{ .helper = @intFromPtr(&helpers.getStr), .t = .{ .reg = rb }, .key = .{ .reg = rc }, .v = .{ .reg = ra }, .key_tag = tag_string } };
                a.jumpIfByte(.ne, tagOf(rb), tag_table, e.coldStep(pc));
                a.jumpIfByte(.ne, tagOf(rc), tag_int, e.addCold(pc, by_name, done));
                a.load64(A.args[0], slot(rb));
                a.load64(A.args[1], slot(rc));
                a.lea(A.args[2], slot(ra));
                a.call(@intFromPtr(&helpers.getArray));
                a.jumpIfImm(.ne, A.ret0, 0, e.coldStep(pc));
                a.bind(done);
            },
            .settable => {
                const done = a.newLabel();
                const by_name: Cold.Kind = .{ .table = .{ .helper = @intFromPtr(&helpers.setStr), .t = .{ .reg = ra }, .key = .{ .reg = rb }, .v = .{ .reg = rc }, .key_tag = tag_string } };
                a.jumpIfByte(.ne, tagOf(ra), tag_table, e.coldStep(pc));
                a.jumpIfByte(.ne, tagOf(rb), tag_int, e.addCold(pc, by_name, done));
                a.mov(A.args[0], A.thread);
                a.load64(A.args[1], slot(ra));
                a.load64(A.args[2], slot(rb));
                a.lea(A.args[3], slot(rc));
                a.call(@intFromPtr(&helpers.setArray));
                a.jumpIfImm(.ne, A.ret0, 0, e.coldStep(pc));
                a.bind(done);
            },
            .self => {
                // The step routine repeats this copy, which is harmless.
                a.copy16(slot(ra + 1), slot(rb));
                e.tableOp(pc, &helpers.getStr, .{ .reg = ra + 1 }, .{ .konst = rc }, .{ .reg = ra });
            },
            .getindex => {
                a.lea(A.args[0], slot(rb));
                a.movImm(A.args[1], rc);
                a.lea(A.args[2], slot(ra));
                a.call(@intFromPtr(&helpers.getIndex));
                a.jumpIfImm(.ne, A.ret0, 0, e.coldStep(pc));
            },
            .len => {
                a.lea(A.args[0], slot(rb));
                a.lea(A.args[1], slot(ra));
                a.call(@intFromPtr(&helpers.length));
                a.jumpIfImm(.ne, A.ret0, 0, e.coldStep(pc));
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
                    a.load64(A.t0, .{ .base = A.thread, .disp = e.lay.global });
                    a.load64(A.t0, .{ .base = A.t0, .disp = e.lay.pending });
                    a.jumpIfImm(.ne, A.t0, 0, e.coldStep(pc));
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
                a.jmp(e.at(pc + 1 - opc.bx(ins)));
            },
            .tforloop => {
                a.load8(A.t0, tagOf(ra + 4));
                a.jumpIfImm(.eq, A.t0, @backingInt(Tag.nil), e.at(pc + 1));
                a.copy16(slot(ra + 2), slot(ra + 4));
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
                a.load64(A.t1, .{ .base = A.t0, .disp = @offsetOf(object.Closure, "proto") });
                a.load64(A.t2, .{ .base = A.t1, .disp = @offsetOf(Proto, "jit_entry") });
                a.jumpIfImm(.eq, A.t2, 0, slow);
                a.movImm(A.t3, pc + 1);
                a.movImm(A.t4, ra);
                a.movImm(A.t5, @as(u32, @bitCast(@as(i32, @intCast(rc)) - 1)));
                if (rb != 0) {
                    a.movImm(A.t6, rb - 1);
                } else {
                    // The arguments run up to the stack top.
                    a.load32(A.t6, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                    a.sub(A.t6, A.base);
                    a.addImm(A.t6, -@as(i32, @intCast(ra + 1)));
                }
                a.callReg(A.t2);
                // The callee returns to the code after this jump, with its
                // result count (zero or one) in t6 and its result, if any,
                // already in R[A].
                a.jmp(slow);
                if (rc == 0) {
                    // Every result is wanted, and the stack top marks
                    // their end.
                    a.mov(A.t0, A.base);
                    a.add(A.t0, A.t6);
                    a.addImm(A.t0, @intCast(ra));
                } else {
                    // Results the callee did not return are nil, and the
                    // register window of this function comes back.
                    if (rc >= 2) {
                        const has_one = a.newLabel();
                        a.jumpIfImm(.ne, A.t6, 0, has_one);
                        e.storeConst(ra, .nil);
                        a.bind(has_one);
                        var i: u32 = 1;
                        while (i + 1 < rc) : (i += 1) e.storeConst(ra + i, .nil);
                    }
                    a.mov(A.t0, A.base);
                    a.addImm(A.t0, e.p.max_stack);
                }
                a.store32(A.t0, .{ .base = A.thread, .disp = @offsetOf(Thread, "top") });
                a.bind(done);
            },
            .tailcall => {
                // Only a Lus function has the fast path.
                a.jumpIfByte(.ne, tagOf(ra), tag_closure, e.coldStep(pc));
                a.mov(A.args[0], A.thread);
                a.mov(A.args[1], A.bp);
                a.movImm(A.args[2], ins);
                a.movImm(A.args[3], pc + 1);
                a.call(@intFromPtr(&helpers.tailcall));
                a.jumpIfImm(.eq, A.ret0, 0, e.coldStep(pc));
                a.mov(A.base, A.ret1);
                e.reloadBp();
                a.jmpReg(A.ret0);
            },
            .ret0, .ret1 => {
                a.movImm(A.t4, ra);
                a.callLocal(e.l_ret[@intFromBool(o == .ret1)]);
                e.step(pc, false);
            },

            // An instruction that never changes the pc by itself falls
            // through to its successor.
            else => e.step(pc, true),
        }
    }

    /// The code a native call enters the function at. The caller passes
    /// the closure in t0, the pc to save in t3, the register of the callee
    /// in t4, the wanted result count in t5, and the argument count in t6.
    /// The entry does what `interp.enterLus` does. It returns to the
    /// caller, with nothing changed, when finalizers are pending or when
    /// the frame list or the stack must grow.
    fn callEntry(e: *Emitter) void {
        const a = &e.a;
        const p = e.p;
        const lay = e.lay;
        const max_stack: i32 = p.max_stack;
        const np: u32 = p.num_params;
        const fail = a.newLabel();
        const thread: A.Reg = A.thread;
        e.call_entry = a.offset();
        a.load64(A.t1, .{ .base = thread, .disp = lay.global });
        a.load64(A.t1, .{ .base = A.t1, .disp = lay.pending });
        a.jumpIfImm(.ne, A.t1, 0, fail);
        a.load64(A.t1, .{ .base = thread, .disp = lay.frames_len });
        a.jumpIfMem(.eq, A.t1, .{ .base = thread, .disp = lay.frames_cap }, fail);
        // t2 = the base of the new frame.
        a.mov(A.t2, A.base);
        a.add(A.t2, A.t4);
        a.addImm(A.t2, 1);
        a.mov(A.t4, A.t2);
        a.add(A.t4, A.t6);
        a.addImm(A.t4, max_stack + 8);
        a.jumpIfMem(.hi, A.t4, .{ .base = thread, .disp = lay.stack_len }, fail);

        // Nothing fails from here on.
        // t4 = the new frame, one past the caller's.
        a.movImm(A.t4, @intCast(frame_size));
        a.mul(A.t4, A.t1);
        a.addImm(A.t1, 1);
        a.store64(A.t1, .{ .base = thread, .disp = lay.frames_len });
        a.load64(A.t1, .{ .base = thread, .disp = lay.frames_ptr });
        a.add(A.t4, A.t1);
        a.store32(A.t3, .{ .base = A.t4, .disp = frameField("pc") - frame_size });
        a.movImm(A.t1, lay.template);
        var off: i32 = 0;
        while (off + 16 <= frame_size) : (off += 16) a.copy16(.{ .base = A.t4, .disp = off }, .{ .base = A.t1, .disp = off });
        while (off < frame_size) : (off += 8) {
            a.load64(A.t3, .{ .base = A.t1, .disp = off });
            a.store64(A.t3, .{ .base = A.t4, .disp = off });
        }
        // The caller continues after the jump that follows its call.
        a.linkPastJump(A.t3);
        a.dropLink();
        a.store64(A.t3, .{ .base = A.t4, .disp = frameField("resume_at") });
        a.store64(A.t0, .{ .base = A.t4, .disp = frameField("closure") });
        a.store32(A.t5, .{ .base = A.t4, .disp = frameField("want") });
        a.store32(A.t2, .{ .base = A.t4, .disp = frameField("base") });
        a.mov(A.t1, A.t2);
        a.addImm(A.t1, -1);
        a.store32(A.t1, .{ .base = A.t4, .disp = frameField("func") });
        a.store32(A.t1, .{ .base = A.t4, .disp = frameField("ret") });
        a.addImm(A.t1, 1 + max_stack);
        a.store32(A.t1, .{ .base = thread, .disp = @offsetOf(Thread, "top") });
        a.mov(A.base, A.t2);
        e.reloadBp();

        // Missing parameters and the registers above the parameters
        // start nil.
        a.zeroPrepare();
        if (np > 0) {
            const fixed = a.newLabel();
            const loop = a.newLabel();
            a.jumpIfImm(.hs, A.t6, @intCast(np), fixed);
            a.bind(loop);
            a.addScaled(A.t1, A.bp, A.t6, 4);
            a.zero16(.{ .base = A.t1 });
            a.addImm(A.t6, 1);
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
            a.addImm(A.t1, 16);
            a.addImm(A.t3, -1);
            a.jumpIfImm(.ne, A.t3, 0, loop);
        }
        const start = a.newLabel();
        a.jmp(start);
        a.bind(fail);
        a.retLocal();
        a.bind(start);
    }

    /// The shared code of `ret0` (n = 0) and `ret1` (n = 1), entered with
    /// the register of the result in t4. It returns from a frame that a
    /// native call pushed when nothing needs closing, as the lean return
    /// of the interpreter does, and continues in the caller. Any other
    /// frame returns to the instruction, which runs the step routine.
    /// The caller's code after the call finishes what
    /// `interp.fast.finishLean` does.
    fn returnRoutine(e: *Emitter, n: u32) void {
        const a = &e.a;
        const lay = e.lay;
        const thread: A.Reg = A.thread;
        const fail = a.newLabel();
        const no_upvals = a.newLabel();
        const no_tbc = a.newLabel();
        a.bind(e.l_ret[n]);
        // t1 = the running frame.
        a.load64(A.t0, .{ .base = thread, .disp = lay.frames_len });
        a.movImm(A.t1, @intCast(frame_size));
        a.mul(A.t1, A.t0);
        a.load64(A.t2, .{ .base = thread, .disp = lay.frames_ptr });
        a.add(A.t1, A.t2);
        a.addImm(A.t1, -frame_size);
        a.jumpIfByte(.eq, .{ .base = A.t1, .disp = frameField("lean") }, 0, fail);
        a.jumpIfByte(.ne, .{ .base = thread, .disp = @offsetOf(Thread, "hook_mask") }, 0, fail);
        // An open upvalue or a to-be-closed variable of this frame needs
        // the general return.
        a.load64(A.t2, .{ .base = thread, .disp = @offsetOf(Thread, "open_upvals") });
        a.jumpIfImm(.eq, A.t2, 0, no_upvals);
        a.load32(A.t2, .{ .base = A.t2, .disp = @offsetOf(object.Upvalue, "level") });
        a.jumpIf(.hs, A.t2, A.base, fail);
        a.bind(no_upvals);
        a.load64(A.t2, .{ .base = thread, .disp = lay.tbc_len });
        a.jumpIfImm(.eq, A.t2, 0, no_tbc);
        a.load64(A.t3, .{ .base = thread, .disp = lay.tbc_ptr });
        a.addScaled(A.t3, A.t3, A.t2, 2);
        a.load32(A.t2, .{ .base = A.t3, .disp = -4 });
        a.jumpIf(.hs, A.t2, A.base, fail);
        a.bind(no_tbc);

        a.dropLink();
        // The result goes to the slot of the called function, which is
        // the one below register 0.
        if (n == 1) {
            a.addScaled(A.t6, A.bp, A.t4, 4);
            a.copy16(.{ .base = A.bp, .disp = -16 }, .{ .base = A.t6 });
        }
        // Pop the frame and continue in the caller, at the address its
        // call left in the frame. The caller adjusts the result count.
        a.addImm(A.t0, -1);
        a.store64(A.t0, .{ .base = thread, .disp = lay.frames_len });
        a.load32(A.base, .{ .base = A.t1, .disp = frameField("base") - frame_size });
        a.load64(A.t3, .{ .base = A.t1, .disp = frameField("resume_at") });
        a.movImm(A.t6, n);
        e.reloadBp();
        a.jmpReg(A.t3);
        a.bind(fail);
        a.retLocal();
    }

    /// t0 = address of the value of upvalue `i` of the running closure,
    /// and `uv` = the upvalue object.
    fn loadUpvalLoc(e: *Emitter, dst: A.Reg, uv: A.Reg, i: u32) void {
        const a = &e.a;
        // The closure is the value below register 0.
        a.load64(uv, .{ .base = A.bp, .disp = -16 });
        a.load64(uv, .{ .base = uv, .disp = @intCast(@sizeOf(object.Closure) + i * @sizeOf(usize)) });
        a.load64(dst, .{ .base = uv, .disp = e.lay.upval_loc });
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

    /// A table access through a fast-path helper that takes the thread,
    /// the table, the key, the inline cache, and the value or result.
    fn tableOp(e: *Emitter, pc: u32, helper: anytype, t: Place, key: Place, v: Place) void {
        // Only a table has a fast path.
        if (t == .reg) e.a.jumpIfByte(.ne, tagOf(t.reg), tag_table, e.coldStep(pc));
        e.tableCall(pc, @intFromPtr(helper), t, key, v);
        e.a.jumpIfImm(.ne, A.ret0, 0, e.coldStep(pc));
    }

    fn tableCall(e: *Emitter, pc: u32, helper: usize, t: Place, key: Place, v: Place) void {
        const a = &e.a;
        a.mov(A.args[0], A.thread);
        e.passPlace(1, t);
        e.passPlace(2, key);
        a.movImm(A.args[3], @intFromPtr(&e.p.ic[pc]));
        e.passPlace(4, v);
        a.call(helper);
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
                a.movImm(A.t1, k.payload);
                // Skip when the result differs from C.
                a.jumpIf(if (c) .ne else .eq, A.t0, A.t1, skip);
            },
            .nil, .false, .true => {
                a.load8(A.t0, tagOf(x));
                a.jumpIfImm(if (c) .ne else .eq, A.t0, @backingInt(k.tag), skip);
            },
            .string => {
                // Two interned strings are equal exactly when they are
                // the same object, and a string that is not interned is
                // longer than any interned one.
                if (!k.as(object.String).flags.interned) return e.step(pc, true);
                const differ = if (c) skip else e.at(pc + 1);
                a.jumpIfByte(.ne, tagOf(x), tag_string, differ);
                a.load64(A.t0, slot(x));
                a.movImm(A.t1, k.payload);
                a.jumpIf(if (c) .ne else .eq, A.t0, A.t1, skip);
            },
            else => e.step(pc, true),
        }
    }

    // -----------------------------------------------------------------
    // Out-of-line code

    fn emitCold(e: *Emitter, c: Cold) void {
        const a = &e.a;
        a.bind(c.entry);
        switch (c.kind) {
            .step => e.step(c.pc, false),
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
                a.movImm(A.args[1], e.p.code[c.pc]);
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
            .table => |t| {
                const slow = a.newLabel();
                a.jumpIfByte(.ne, tagOf(t.key.reg), t.key_tag, slow);
                e.tableCall(c.pc, t.helper, t.t, t.key, t.v);
                a.jumpIfImm(.eq, A.ret0, 0, c.resume_at);
                a.bind(slow);
                e.step(c.pc, false);
            },
        }
    }
};
