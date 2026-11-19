//! The template emitter. It walks the bytecode of a function once and
//! emits native code for each instruction: an inline fast path where one
//! pays off, and a call to the opcode's step routine for everything else.
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
const interp = @import("../vm/interp.zig");
const opc = @import("../compile/opcodes.zig");
const jit = @import("jit.zig");
const helpers = @import("helpers.zig");
const Thread = state.Thread;
const Proto = object.Proto;
const Value = value.Value;
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

/// Byte offsets inside runtime structures, measured on a live thread so
/// that they follow whatever layout the compiler chose.
const Layout = struct {
    stack_ptr: i32,

    fn of(l: *Thread) Layout {
        const b = @intFromPtr(l);
        return .{
            .stack_ptr = @intCast(@intFromPtr(&l.stack.ptr) - b),
        };
    }
};

pub const Emitter = struct {
    a: A.Assembler,
    p: *Proto,
    lay: Layout,
    /// Label of instruction 0. The label of instruction `pc` follows.
    first: Label = 0,
    l_status: Label = 0,
    l_dispatch: Label = 0,
    l_exit: Label = 0,

    pub fn init(gpa: std.mem.Allocator, l: *Thread, p: *Proto) Emitter {
        return .{ .a = A.Assembler.init(gpa), .p = p, .lay = Layout.of(l) };
    }

    pub fn deinit(e: *Emitter) void {
        e.a.deinit();
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

        var pc: u32 = 0;
        while (pc < code.len) : (pc += 1) {
            a.bind(e.first + pc);
            e.instruction(pc, code[pc]);
        }
        // Execution never runs off the end of a function.
        a.bind(e.first + pc);
        a.trap();

        if (!a.finish()) return false;
        for (offs, 0..) |*o, i| o.* = a.labelOffset(e.first + @as(u32, @intCast(i)));
        return true;
    }

    /// bp = stack + base * 16. Runs after anything that may have moved
    /// the stack or changed the frame.
    fn reloadBp(e: *Emitter) void {
        e.a.load64(A.bp, .{ .base = A.thread, .disp = e.lay.stack_ptr });
        e.a.addScaled(A.bp, A.bp, A.base, 4);
    }

    /// Calls the step routine of the instruction at `pc`.
    fn step(e: *Emitter, pc: u32, o: Op) void {
        const a = &e.a;
        a.mov(A.args[0], A.thread);
        a.movImm(A.args[1], pc + 1);
        a.mov(A.args[2], A.stop);
        a.call(@intFromPtr(helpers.steps[@backingInt(o)]));
        a.jumpIfImm(.ne, A.ret0, 0, e.l_status);
        e.reloadBp();
    }

    fn instruction(e: *Emitter, pc: u32, ins: u32) void {
        const o = opc.op(ins);
        switch (o) {
            // The operand word of the previous instruction.
            .extraarg => e.a.trap(),
            else => e.step(pc, o),
        }
    }
};
