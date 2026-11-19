//! The WebAssembly backend of the baseline JIT. In the WebAssembly build a
//! hot function compiles to a small WebAssembly module, which the host
//! instantiates against the memory and the function table of the runtime
//! and installs in that table. The design is described in
//! `spec/design/wasmjit.md`.
//!
//! The module holds one function, `f(l, stop, pc) -> status`, which runs
//! the frame of the function from instruction `pc`. Its body is a loop
//! around a `br_table` with one case per instruction. Each instruction is
//! either an inline fast path or a call to the step routine of its opcode,
//! exactly as in the native backends, and every case it does not handle
//! runs the step routine. A forward jump is a direct branch, a backward
//! jump goes through the dispatch at the head of the loop, and a step
//! that pushed or popped a frame returns to the trampoline in `run`.
//!
//! The step routines, the fast-path helpers, and the compile callback of
//! the host are entries of the function table of the runtime. The module
//! imports each one it uses under the name of its table index.

const std = @import("std");
const state = @import("../vm/state.zig");
const object = @import("../vm/object.zig");
const value = @import("../vm/value.zig");
const gc = @import("../vm/gc.zig");
const interp = @import("../vm/interp.zig");
const table = @import("../vm/table.zig");
const opc = @import("../compile/opcodes.zig");
const jit = @import("jit.zig");
const helpers = @import("helpers.zig");
const Thread = state.Thread;
const Frame = state.Frame;
const Proto = object.Proto;
const Value = value.Value;
const Tag = value.Tag;
const Op = opc.Op;
const Step = interp.Step;
const tl = table.layout;
const il = interp.layout;

const tag_nil: u8 = @backingInt(Tag.nil);
const tag_false: u8 = @backingInt(Tag.false);
const tag_int: u8 = @backingInt(Tag.integer);
const tag_float: u8 = @backingInt(Tag.float);
const tag_string: u8 = @backingInt(Tag.string);
const tag_table: u8 = @backingInt(Tag.table);
const tag_closure: u8 = @backingInt(Tag.closure);

/// Functions with more instructions than this stay in the interpreter.
/// The dispatch of a function nests one block per instruction, and engines
/// take longer to compile deep nests.
const max_instructions = 30_000;

// ---------------------------------------------------------------------
// The host

/// Table index of the compile function of the host, or zero when the host
/// cannot instantiate modules.
var host_compile: u32 = 0;

/// What the host answers when it compiles a module in the background.
const pending: u32 = 0xFFFF_FFFF;

/// `compile(ptr, len, reuse)` instantiates the module of `len` bytes at
/// `ptr` and returns the table index of its function, zero when it
/// failed, or `pending`. A nonzero `reuse` is a table slot whose code was
/// freed, which the host may fill instead of growing the table.
const HostCompile = *const fn (ptr: [*]const u8, len: usize, reuse: u32) callconv(.c) u32;

/// How deep compiled code calls compiled code on the WebAssembly stack.
/// All activations share the count, so that natives that call back into
/// Lus cannot multiply it.
var nest_depth: u32 = 0;
const max_nest = 100;

/// The signature of compiled code.
const Code = *const fn (l: *Thread, stop: usize, pc: u32) callconv(.c) u32;

/// Table slots whose code was freed. All states of the module share the
/// table, so they share this list.
var free_slots: std.ArrayList(u32) = .empty;
const slot_gpa = std.heap.c_allocator;

/// Registers the compile function of the host, which lives at table
/// index `index`.
pub fn setHost(index: u32) void {
    host_compile = index;
}

/// Whether the host compiles modules.
pub fn available() bool {
    return host_compile != 0;
}

/// Statistics for the host and the benchmarks.
pub var stats: extern struct {
    /// Functions compiled, and modules the host declined or deferred.
    compiled: u32 = 0,
    failed: u32 = 0,
    deferred: u32 = 0,
    /// Bytes of modules handed to the host.
    bytes: u32 = 0,
} = .{};

pub fn compile(l: *Thread, p: *Proto) jit.Outcome {
    if (!available()) return .failed;
    if (p.code.len == 0 or p.code.len > max_instructions) return .failed;
    const g = l.g;
    var e = Emitter.init(g.gpa, l, p);
    defer e.deinit();
    const bytes = e.module() orelse return .failed;
    const reuse: u32 = if (free_slots.items.len > 0) free_slots.items[free_slots.items.len - 1] else 0;
    const host: HostCompile = @ptrFromInt(host_compile);
    const index = host(bytes.ptr, bytes.len, reuse);
    stats.bytes +%= @intCast(bytes.len);
    if (index == pending) {
        stats.deferred += 1;
        return .later;
    }
    if (index == 0) {
        stats.failed += 1;
        return .failed;
    }
    if (index == reuse) _ = free_slots.pop();
    stats.compiled += 1;
    p.jit_code = @ptrFromInt(index);
    p.plain_call = false;
    g.jit.live += 1;
    g.jit.compiled += 1;
    return .done;
}

/// Returns the table slot of a function that is being collected.
pub fn release(p: *Proto) void {
    free_slots.append(slot_gpa, @intCast(@intFromPtr(p.jit_code.?))) catch {};
}

/// Runs frames in compiled code, starting with the top frame, until the
/// frame count drops to `stop` or a frame needs the interpreter. Calls
/// and returns between Lus functions come back here, so compiled code
/// never recurses on the WebAssembly stack.
pub fn run(l: *Thread, stop: usize) (state.Error || interp.YieldError || interp.LoopError)!void {
    while (true) {
        if (l.hook_mask != 0) return error.SwitchLoop;
        const fr = l.frame();
        const cl = fr.closure orelse return error.SwitchLoop;
        const p = cl.proto;
        if (p.jit_code == null) {
            // A call into a function without code counts toward its
            // threshold, as it does in the interpreter.
            if (fr.pc != 0) return error.SwitchLoop;
            p.hot -%= 1;
            if (p.hot != 0 or !jit.expire(l, p)) return error.SwitchLoop;
        }
        const code: Code = @ptrFromInt(@intFromPtr(p.jit_code.?));
        switch (code(l, stop, fr.pc)) {
            Step.dispatch => continue,
            Step.done => return,
            Step.failed => return error.LusError,
            Step.yielded => return error.Yield,
            else => return error.SwitchLoop,
        }
    }
}

/// The `call` instruction `ins` of the frame at `depth`, whose next
/// instruction is `pc`, for compiled code. A native function runs through
/// the helper that mirrors the interpreter. A Lus function with fixed
/// parameters gets its frame from `interp.enterLus`, and anything else
/// from the step routine of `call`. When the frame on top then belongs to
/// a function with compiled code, that code runs from here with the
/// caller as its stop, so that it returns here when the callee returns,
/// and this reports "next" like a step that finished the call. Calls nest
/// at most `max_nest` deep this way. Deeper calls, and everything else
/// that changes the frames, report "dispatch" and go to the trampoline.
fn callFromCode(l: *Thread, ins: u32, pc: u32, stop: usize, depth: u32) callconv(.c) u32 {
    const fr = &l.frames.items[depth - 1];
    const func = fr.base + opc.a(ins);
    const callee = l.stack[func];
    var st: u32 = Step.dispatch;
    if (callee.tag == .native) {
        st = @intCast(helpers.callNative(l, ins, pc));
        if (st != helpers.retry) return st;
    }
    const want: i32 = @as(i32, opc.c(ins)) - 1;
    if (callee.tag == .closure and !callee.as(object.Closure).proto.is_vararg and l.g.tobefnz.items.len == 0) {
        fr.pc = pc;
        const nb = opc.b(ins);
        const nargs: u32 = if (nb != 0) nb - 1 else l.top - func - 1;
        interp.enterLus(l, callee.as(object.Closure), func, nargs, want) catch return Step.failed;
    } else {
        st = @intCast(helpers.steps[@backingInt(Op.call)](l, pc, stop, ins));
        if (st <= Step.skip) return st;
    }
    while (st == Step.dispatch and l.frames.items.len == depth + 1 and nest_depth < max_nest) {
        const top = l.frame();
        const cl = top.closure orelse break;
        const code_ptr = cl.proto.jit_code orelse break;
        const code: Code = @ptrFromInt(@intFromPtr(code_ptr));
        nest_depth += 1;
        st = code(l, depth, top.pc);
        nest_depth -= 1;
        if (st == Step.done) {
            // The callee returned to this frame. A fixed result count
            // restores the register window of this function, as
            // `interp.doReturn` does when it returns into a caller above
            // its stop.
            const caller = &l.frames.items[depth - 1];
            if (want >= 0) l.top = caller.base + caller.closure.?.proto.max_stack;
            // The callee may have set a hook, which the interpreter runs.
            return if (l.hook_mask != 0) Step.interpret else Step.next;
        }
    }
    return st;
}

// ---------------------------------------------------------------------
// Encoding

const Valtype = enum(u8) { i32 = 0x7f, i64 = 0x7e, f64 = 0x7c };

const Sig = struct { params: []const Valtype, result: ?Valtype };

/// Every function type a module uses. The index in this list is the type
/// index in the module.
const sigs = [_]Sig{
    // Compiled code, `getIndex`, `callNative`.
    .{ .params = &.{ .i32, .i32, .i32 }, .result = .i32 },
    // Step routines.
    .{ .params = &.{ .i32, .i32, .i32, .i32 }, .result = .i32 },
    // `getStr` and `setStr`.
    .{ .params = &.{ .i32, .i32, .i32, .i32, .i32 }, .result = .i32 },
    // `getArray`.
    .{ .params = &.{ .i32, .i64, .i32 }, .result = .i32 },
    // `setArray`.
    .{ .params = &.{ .i32, .i32, .i64, .i32 }, .result = .i32 },
    // `length`.
    .{ .params = &.{ .i32, .i32 }, .result = .i32 },
    // `barrier`.
    .{ .params = &.{ .i32, .i32 }, .result = null },
    // `barrierTable`.
    .{ .params = &.{ .i32, .i32, .i32, .i32 }, .result = null },
    // `callFromCode`.
    .{ .params = &.{ .i32, .i32, .i32, .i32, .i32 }, .result = .i32 },
    // The call function of a module.
    .{ .params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .result = .i32 },
};
const sig_code = 0;
const sig_step = 1;
const sig_str = 2;
const sig_get_array = 3;
const sig_set_array = 4;
const sig_length = 5;
const sig_barrier = 6;
const sig_barrier_table = 7;
const sig_call = 8;
const sig_module_call = 9;

/// Opcodes of the WebAssembly instructions the emitter uses.
const W = struct {
    const @"unreachable" = 0x00;
    const block = 0x02;
    const loop = 0x03;
    const @"if" = 0x04;
    const @"else" = 0x05;
    const end = 0x0b;
    const br = 0x0c;
    const br_if = 0x0d;
    const br_table = 0x0e;
    const @"return" = 0x0f;
    const call = 0x10;
    const call_indirect = 0x11;
    const drop = 0x1a;
    const select = 0x1b;
    const local_get = 0x20;
    const local_set = 0x21;
    const local_tee = 0x22;
    const i32_load = 0x28;
    const i64_load = 0x29;
    const f64_load = 0x2b;
    const i32_load8_u = 0x2d;
    const i32_load16_u = 0x2f;
    const i32_store = 0x36;
    const i64_store = 0x37;
    const f64_store = 0x39;
    const i32_store16 = 0x3b;
    const i32_const = 0x41;
    const i64_const = 0x42;
    const f64_const = 0x44;
    const i32_eqz = 0x45;
    const i32_eq = 0x46;
    const i32_lt_s = 0x48;
    const i32_ge_s = 0x4e;
    const i32_ne = 0x47;
    const i32_gt_s = 0x4a;
    const i32_lt_u = 0x49;
    const i32_gt_u = 0x4b;
    const i32_le_u = 0x4d;
    const i32_ge_u = 0x4f;
    const i64_eqz = 0x50;
    const i64_eq = 0x51;
    const i64_ne = 0x52;
    const i64_lt_s = 0x53;
    const i64_le_s = 0x57;
    const i64_ge_u = 0x5a;
    const f64_eq = 0x61;
    const f64_lt = 0x63;
    const f64_le = 0x65;
    const i32_add = 0x6a;
    const i32_sub = 0x6b;
    const i32_mul = 0x6c;
    const i32_and = 0x71;
    const i32_shl = 0x74;
    const i64_add = 0x7c;
    const i64_sub = 0x7d;
    const i64_mul = 0x7e;
    const i64_div_s = 0x7f;
    const i64_rem_s = 0x81;
    const i64_and = 0x83;
    const i64_or = 0x84;
    const i64_xor = 0x85;
    const f64_neg = 0x9a;
    const f64_add = 0xa0;
    const f64_sub = 0xa1;
    const f64_mul = 0xa2;
    const f64_div = 0xa3;
    const i32_wrap_i64 = 0xa7;
    const i64_extend_i32_u = 0xad;
    const f64_convert_i64_s = 0xb9;
    const void_type = 0x40;
};

const Buf = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    oom: bool = false,

    fn byte(b: *Buf, x: u8) void {
        b.list.append(b.gpa, x) catch {
            b.oom = true;
        };
    }

    fn bytes(b: *Buf, xs: []const u8) void {
        b.list.appendSlice(b.gpa, xs) catch {
            b.oom = true;
        };
    }

    fn uleb(b: *Buf, x: u64) void {
        var v = x;
        while (true) {
            const low: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) return b.byte(low);
            b.byte(low | 0x80);
        }
    }

    fn sleb(b: *Buf, x: i64) void {
        var v = x;
        while (true) {
            const low: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7f);
            v >>= 7;
            const done = (v == 0 and low & 0x40 == 0) or (v == -1 and low & 0x40 != 0);
            if (done) return b.byte(low);
            b.byte(low | 0x80);
        }
    }

    fn name(b: *Buf, s: []const u8) void {
        b.uleb(s.len);
        b.bytes(s);
    }

    /// Appends a section with its id and size.
    fn section(b: *Buf, id: u8, body: []const u8) void {
        b.byte(id);
        b.uleb(body.len);
        b.bytes(body);
    }
};

// ---------------------------------------------------------------------
// The emitter

/// Locals of compiled code. The first three are the parameters.
const L = struct {
    const l = 0;
    const stop = 1;
    const pc = 2;
    /// Address of register 0.
    const bp = 3;
    /// Stack index of register 0.
    const base = 4;
    /// The frame count while this function runs its frame.
    const depth = 5;
    /// The status a step returned.
    const st = 6;
    const t0 = 7;
    const t1 = 8;
    const t2 = 9;
    const t3 = 10;
    const t4 = 11;
    const x0 = 12;
    const x1 = 13;
    const x2 = 14;
    const f0 = 15;
    const f1 = 16;
};

/// Locals of the call function of a module. The first eight are the
/// parameters.
const C = struct {
    const l = 0;
    const stop = 1;
    const depth = 2;
    /// The pc to save in the caller.
    const pc = 3;
    const ins = 4;
    /// The stack index of the callee.
    const func = 5;
    /// The argument count, or -1 when the arguments run up to the top.
    const nargs = 6;
    const want = 7;
    const t0 = 8;
    const t1 = 9;
    const t2 = 10;
    const t3 = 11;
    const t4 = 12;
    const st = 13;
};

/// Byte offsets inside runtime structures, measured on a live thread so
/// that they follow whatever layout the compiler chose.
const Layout = struct {
    stack_ptr: u32,
    stack_len: u32,
    frames_ptr: u32,
    frames_len: u32,
    frames_cap: u32,
    tbc_ptr: u32,
    tbc_len: u32,
    global: u32,
    pending: u32,
    hash_ptr: u32,
    hash_len: u32,

    fn of(l: *Thread) Layout {
        const b = @intFromPtr(l);
        const g = l.g;
        return .{
            .stack_ptr = @intCast(@intFromPtr(&l.stack.ptr) - b),
            .stack_len = @intCast(@intFromPtr(&l.stack.len) - b),
            .frames_cap = @intCast(@intFromPtr(&l.frames.capacity) - b),
            .tbc_ptr = @intCast(@intFromPtr(&l.tbc.items.ptr) - b),
            .tbc_len = @intCast(@intFromPtr(&l.tbc.items.len) - b),
            .frames_ptr = @intCast(@intFromPtr(&l.frames.items.ptr) - b),
            .frames_len = @intCast(@intFromPtr(&l.frames.items.len) - b),
            .global = @offsetOf(Thread, "g"),
            .pending = @intCast(@intFromPtr(&g.tobefnz.items.len) - @intFromPtr(g)),
            .hash_ptr = @intCast(tl.hashPtr()),
            .hash_len = @intCast(tl.hashLen()),
        };
    }
};

/// An operand that is a register or a constant.
const Operand = union(enum) {
    reg: u32,
    int: i64,
    float: f64,
};

/// Where a value lives.
const Place = union(enum) {
    reg: u32,
    konst: u32,
    upval: u32,
};

const ArithOp = enum { add, sub, mul, div };
const CompareOp = enum { lt, le, eq };

const Import = struct { index: u32, sig: u8 };

const Emitter = struct {
    gpa: std.mem.Allocator,
    p: *Proto,
    lay: Layout,
    out: Buf,
    imports: std.ArrayList(Import) = .empty,
    /// The instruction being emitted, the instruction count, and the
    /// blocks opened inside the code of the instruction.
    cur: u32 = 0,
    n: u32 = 0,
    inner: u32 = 0,
    oom: bool = false,
    /// Whether a frame of the function can own an open upvalue, and a
    /// to-be-closed variable. A return tests only for what can exist.
    captures: bool = false,
    closes: bool = false,
    /// Offsets in the body of the calls of the call function of the
    /// module, whose index is known only once every import is.
    call_sites: std.ArrayList(u32) = .empty,

    fn init(gpa: std.mem.Allocator, l: *Thread, p: *Proto) Emitter {
        return .{ .gpa = gpa, .p = p, .lay = .of(l), .out = .{ .gpa = gpa }, .n = @intCast(p.code.len) };
    }

    fn deinit(e: *Emitter) void {
        e.out.list.deinit(e.gpa);
        e.imports.deinit(e.gpa);
        e.call_sites.deinit(e.gpa);
    }

    // -----------------------------------------------------------------
    // Instructions of the body

    fn op(e: *Emitter, x: u8) void {
        e.out.byte(x);
    }

    fn get(e: *Emitter, local: u32) void {
        e.op(W.local_get);
        e.out.uleb(local);
    }

    fn set(e: *Emitter, local: u32) void {
        e.op(W.local_set);
        e.out.uleb(local);
    }

    fn tee(e: *Emitter, local: u32) void {
        e.op(W.local_tee);
        e.out.uleb(local);
    }

    fn i32c(e: *Emitter, x: i64) void {
        e.op(W.i32_const);
        e.out.sleb(@as(i32, @truncate(x)));
    }

    fn u32c(e: *Emitter, x: u32) void {
        e.op(W.i32_const);
        e.out.sleb(@as(i32, @bitCast(x)));
    }

    fn i64c(e: *Emitter, x: i64) void {
        e.op(W.i64_const);
        e.out.sleb(x);
    }

    fn f64c(e: *Emitter, x: f64) void {
        e.op(W.f64_const);
        e.out.bytes(std.mem.asBytes(&x));
    }

    fn mem(e: *Emitter, x: u8, align_log: u8, offset: u32) void {
        e.op(x);
        e.out.uleb(align_log);
        e.out.uleb(offset);
    }

    fn load32(e: *Emitter, offset: u32) void {
        e.mem(W.i32_load, 2, offset);
    }
    fn load64(e: *Emitter, offset: u32) void {
        e.mem(W.i64_load, 3, offset);
    }
    fn load8(e: *Emitter, offset: u32) void {
        e.mem(W.i32_load8_u, 0, offset);
    }
    fn store32(e: *Emitter, offset: u32) void {
        e.mem(W.i32_store, 2, offset);
    }
    fn store64(e: *Emitter, offset: u32) void {
        e.mem(W.i64_store, 3, offset);
    }

    fn block(e: *Emitter) void {
        e.op(W.block);
        e.op(W.void_type);
        e.inner += 1;
    }

    fn ifThen(e: *Emitter) void {
        e.op(W.@"if");
        e.op(W.void_type);
        e.inner += 1;
    }

    fn end(e: *Emitter) void {
        e.op(W.end);
        e.inner -= 1;
    }

    fn br(e: *Emitter, depth: u32) void {
        e.op(W.br);
        e.out.uleb(depth);
    }

    fn brIf(e: *Emitter, depth: u32) void {
        e.op(W.br_if);
        e.out.uleb(depth);
    }

    /// Branch depth of the block that ends right before the code of
    /// instruction `t`, which must follow the current one.
    fn depthOf(e: *Emitter, t: u32) u32 {
        std.debug.assert(t > e.cur);
        return e.inner + (t - e.cur - 1);
    }

    fn depthStatus(e: *Emitter) u32 {
        return e.inner + (e.n - e.cur);
    }

    fn depthLoop(e: *Emitter) u32 {
        return e.inner + (e.n - e.cur) + 1;
    }

    /// Continues at instruction `t`.
    fn goto(e: *Emitter, t: u32) void {
        if (t > e.cur) {
            if (t == e.cur + 1 and e.inner == 0) return;
            e.br(e.depthOf(t));
        } else {
            e.u32c(t);
            e.set(L.pc);
            e.br(e.depthLoop());
        }
    }

    /// Continues at instruction `t` when the value on the stack is
    /// nonzero.
    fn gotoIf(e: *Emitter, t: u32) void {
        if (t > e.cur) {
            e.brIf(e.depthOf(t));
        } else {
            e.ifThen();
            e.goto(t);
            e.end();
        }
    }

    /// Continues at the instruction after the current one.
    fn next(e: *Emitter) void {
        e.goto(e.cur + 1);
    }

    /// Function index of the import of the table entry `index`.
    fn import(e: *Emitter, index: usize, sig: u8) u32 {
        const idx: u32 = @intCast(index);
        for (e.imports.items, 0..) |im, i| if (im.index == idx) return @intCast(i);
        e.imports.append(e.gpa, .{ .index = idx, .sig = sig }) catch {
            e.oom = true;
        };
        return @intCast(e.imports.items.len - 1);
    }

    fn call(e: *Emitter, f: usize, sig: u8) void {
        const i = e.import(f, sig);
        e.op(W.call);
        e.out.uleb(i);
    }

    // -----------------------------------------------------------------
    // Building blocks

    fn slotOff(r: u32) u32 {
        return r * 16;
    }

    fn tagOff(r: u32) u32 {
        return r * 16 + 8;
    }

    /// bp = stack + base * 16. Runs after anything that may have moved
    /// the stack.
    fn reloadBp(e: *Emitter) void {
        e.get(L.l);
        e.load32(e.lay.stack_ptr);
        e.get(L.base);
        e.i32c(4);
        e.op(W.i32_shl);
        e.op(W.i32_add);
        e.set(L.bp);
    }

    /// Reads the base of the top frame, which is the frame of this
    /// function, and points bp at its registers.
    fn loadFrame(e: *Emitter) void {
        e.frameAddr();
        e.load32(@offsetOf(Frame, "base"));
        e.set(L.base);
        e.reloadBp();
    }

    /// Pushes the address of the frame of this function.
    fn frameAddr(e: *Emitter) void {
        e.get(L.l);
        e.load32(e.lay.frames_ptr);
        e.get(L.depth);
        e.i32c(1);
        e.op(W.i32_sub);
        e.i32c(@sizeOf(Frame));
        e.op(W.i32_mul);
        e.op(W.i32_add);
    }

    /// Pushes the tag byte of register `r`.
    fn tagOf(e: *Emitter, r: u32) void {
        e.get(L.bp);
        e.load8(tagOff(r));
    }

    /// Branches `depth` out unless register `r` holds `tag`.
    fn guardTag(e: *Emitter, r: u32, tag: u8, depth: u32) void {
        e.tagOf(r);
        e.i32c(tag);
        e.op(W.i32_ne);
        e.brIf(depth);
    }

    /// Branches `depth` out unless the operand is a register holding
    /// `tag`. Constants were checked when the instruction was compiled.
    fn guard(e: *Emitter, o: Operand, tag: u8, depth: u32) void {
        switch (o) {
            .reg => |r| e.guardTag(r, tag, depth),
            else => {},
        }
    }

    /// Stores the tag `tag` into register `r`.
    fn storeTag(e: *Emitter, r: u32, tag: u8) void {
        e.get(L.bp);
        e.i64c(tag);
        e.store64(tagOff(r));
    }

    /// Stores a constant value into register `r`.
    fn storeConst(e: *Emitter, r: u32, v: Value) void {
        const w: *const [2]u64 = @ptrCast(&v);
        e.get(L.bp);
        e.i64c(@bitCast(w[0]));
        e.store64(slotOff(r));
        e.get(L.bp);
        e.i64c(@bitCast(w[1]));
        e.store64(tagOff(r));
    }

    /// Copies 16 bytes from `src + soff` to `dst + doff`, both addresses
    /// held in locals.
    fn copy16(e: *Emitter, dst: u32, doff: u32, src: u32, soff: u32) void {
        e.get(dst);
        e.get(src);
        e.load64(soff);
        e.store64(doff);
        e.get(dst);
        e.get(src);
        e.load64(soff + 8);
        e.store64(doff + 8);
    }

    fn loadInt(e: *Emitter, o: Operand) void {
        switch (o) {
            .reg => |r| {
                e.get(L.bp);
                e.load64(slotOff(r));
            },
            .int => |v| e.i64c(v),
            .float => unreachable,
        }
    }

    /// Pushes a float operand. An integer constant converts.
    fn loadFloat(e: *Emitter, o: Operand) void {
        switch (o) {
            .reg => |r| {
                e.get(L.bp);
                e.mem(W.f64_load, 3, slotOff(r));
            },
            .int => |v| e.f64c(@floatFromInt(v)),
            .float => |v| e.f64c(v),
        }
    }

    /// Pushes an operand converted to a float from an integer.
    fn loadIntAsFloat(e: *Emitter, o: Operand) void {
        e.loadInt(o);
        e.op(W.f64_convert_i64_s);
    }

    fn constOperand(e: *Emitter, k: u32) ?Operand {
        const v = e.p.constants[k];
        return switch (v.tag) {
            .integer => .{ .int = v.asInt() },
            .float => .{ .float = v.asFloat() },
            else => null,
        };
    }

    /// Calls the step routine of the current instruction and continues
    /// at the next instruction, at the one after it, or, for any other
    /// status, at the status handler.
    fn step(e: *Emitter) void {
        const pc = e.cur;
        const ins = e.p.code[pc];
        e.get(L.l);
        e.u32c(pc + 1);
        e.get(L.stop);
        e.u32c(ins);
        e.call(@intFromPtr(helpers.steps[@backingInt(opc.op(ins))]), sig_step);
        e.stepResult();
    }

    /// Continues as the step code on the stack says: at the next
    /// instruction, at the one after it, or at the status handler.
    fn stepResult(e: *Emitter) void {
        e.tee(L.st);
        e.i32c(Step.skip);
        e.op(W.i32_gt_u);
        e.brIf(e.depthStatus());
        e.reloadBp();
        e.get(L.st);
        e.gotoIf(@min(e.cur + 2, e.n));
        e.next();
    }

    /// Branches to the status handler with the status in `st` when it is
    /// not zero, after a helper that returns an `interp.Step` code.
    fn statusIfSet(e: *Emitter) void {
        e.get(L.st);
        e.brIf(e.depthStatus());
    }

    // -----------------------------------------------------------------
    // The module

    /// Emits the whole module. Returns its bytes, which live until the
    /// emitter is freed, or null when the function cannot be compiled.
    fn module(e: *Emitter) ?[]const u8 {
        const body = e.function() orelse return null;
        defer e.gpa.free(body);
        const calls = e.call_sites.items.len > 0;
        const call_body = if (calls) e.callFunction() orelse return null else &.{};
        defer if (calls) e.gpa.free(call_body);
        // The call function follows the main function.
        const call_index: u32 = @intCast(e.imports.items.len + 1);
        for (e.call_sites.items) |at| {
            var x = call_index;
            for (body[at..][0..5], 0..) |*byte, i| {
                byte.* = @as(u8, @truncate(x & 0x7f)) | @as(u8, if (i < 4) 0x80 else 0);
                x >>= 7;
            }
        }
        var m: Buf = .{ .gpa = e.gpa };
        var sec: Buf = .{ .gpa = e.gpa };
        defer sec.list.deinit(e.gpa);
        m.bytes("\x00asm\x01\x00\x00\x00");

        // Types.
        sec.uleb(sigs.len);
        for (sigs) |s| {
            sec.byte(0x60);
            sec.uleb(s.params.len);
            for (s.params) |t| sec.byte(@backingInt(t));
            if (s.result) |r| {
                sec.byte(1);
                sec.byte(@backingInt(r));
            } else sec.byte(0);
        }
        m.section(1, sec.list.items);

        // Imports: the memory of the runtime and the table entries the
        // body calls, each under the decimal name of its index.
        sec.list.clearRetainingCapacity();
        sec.uleb(e.imports.items.len + 1 + @intFromBool(calls));
        sec.name("env");
        sec.name("memory");
        sec.byte(0x02);
        sec.byte(0x00);
        sec.uleb(0);
        if (calls) {
            // The call function reaches compiled code through the table.
            sec.name("env");
            sec.name("table");
            sec.byte(0x01);
            sec.byte(0x70);
            sec.byte(0x00);
            sec.uleb(0);
        }
        for (e.imports.items) |im| {
            var digits: [10]u8 = undefined;
            sec.name("t");
            sec.name(std.fmt.bufPrint(&digits, "{d}", .{im.index}) catch unreachable);
            sec.byte(0x00);
            sec.uleb(im.sig);
        }
        m.section(2, sec.list.items);

        // The function and its export.
        sec.list.clearRetainingCapacity();
        sec.uleb(1 + @as(u32, @intFromBool(calls)));
        sec.uleb(sig_code);
        if (calls) sec.uleb(sig_module_call);
        m.section(3, sec.list.items);
        sec.list.clearRetainingCapacity();
        sec.uleb(1);
        sec.name("f");
        sec.byte(0x00);
        sec.uleb(e.imports.items.len);
        m.section(7, sec.list.items);

        // The code.
        sec.list.clearRetainingCapacity();
        sec.uleb(1 + @as(u32, @intFromBool(calls)));
        var locals: Buf = .{ .gpa = e.gpa };
        defer locals.list.deinit(e.gpa);
        locals.uleb(3);
        locals.uleb(L.x0 - L.bp);
        locals.byte(@backingInt(Valtype.i32));
        locals.uleb(L.f0 - L.x0);
        locals.byte(@backingInt(Valtype.i64));
        locals.uleb(L.f1 - L.f0 + 1);
        locals.byte(@backingInt(Valtype.f64));
        sec.uleb(locals.list.items.len + body.len);
        sec.bytes(locals.list.items);
        sec.bytes(body);
        if (calls) {
            const call_locals = [_]u8{ 1, C.st - C.t0 + 1, @backingInt(Valtype.i32) };
            sec.uleb(call_locals.len + call_body.len);
            sec.bytes(&call_locals);
            sec.bytes(call_body);
        }
        m.section(10, sec.list.items);

        if (m.oom or sec.oom or locals.oom) {
            m.list.deinit(e.gpa);
            return null;
        }
        e.out.list.deinit(e.gpa);
        e.out.list = m.list;
        return e.out.list.items;
    }

    /// Emits the body of the call function of the module and returns it,
    /// owned by the caller. The function makes the call that `call`
    /// instructions of compiled code make, with the same result codes as
    /// `callFromCode`, which it calls for everything but its fast case: a
    /// Lus function with fixed parameters and compiled code, called with
    /// room for its frame. It pushes the frame as `interp.enterLus` does
    /// and runs the code of the callee with the caller as its stop.
    fn callFunction(e: *Emitter) ?[]u8 {
        const saved = e.out;
        e.out = .{ .gpa = e.gpa };
        e.inner = 0;
        const lay = e.lay;
        const nest: u32 = @intCast(@intFromPtr(&nest_depth));
        e.block(); // slow
        // t0 = the address of the callee, t1 = the closure, t2 = its
        // function.
        e.get(C.l);
        e.load32(lay.stack_ptr);
        e.get(C.func);
        e.i32c(4);
        e.op(W.i32_shl);
        e.op(W.i32_add);
        e.tee(C.t0);
        e.load8(8);
        e.i32c(tag_closure);
        e.op(W.i32_ne);
        e.brIf(0);
        e.get(C.t0);
        e.load32(0);
        e.tee(C.t1);
        e.load32(@offsetOf(object.Closure, "proto"));
        e.tee(C.t2);
        e.load8(@offsetOf(Proto, "is_vararg"));
        e.brIf(0);
        e.get(C.t2);
        e.load32(@offsetOf(Proto, "jit_code"));
        e.op(W.i32_eqz);
        e.brIf(0);
        e.u32c(nest);
        e.load32(0);
        e.i32c(max_nest);
        e.op(W.i32_ge_u);
        e.brIf(0);
        e.get(C.l);
        e.load32(lay.global);
        e.load32(lay.pending);
        e.brIf(0);
        e.get(C.l);
        e.load32(lay.frames_len);
        e.get(C.l);
        e.load32(lay.frames_cap);
        e.op(W.i32_ge_u);
        e.brIf(0);
        // t4 = the base of the new frame, t3 = the argument count.
        e.get(C.func);
        e.i32c(1);
        e.op(W.i32_add);
        e.set(C.t4);
        e.get(C.nargs);
        e.i32c(0);
        e.op(W.i32_lt_s);
        e.ifThen();
        // The arguments run up to the stack top.
        e.get(C.l);
        e.load32(@offsetOf(Thread, "top"));
        e.get(C.t4);
        e.op(W.i32_sub);
        e.set(C.nargs);
        e.end();
        e.get(C.nargs);
        e.set(C.t3);
        // The registers of the callee must fit.
        e.get(C.t4);
        e.get(C.t2);
        e.load8(@offsetOf(Proto, "max_stack"));
        e.op(W.i32_add);
        e.get(C.t3);
        e.op(W.i32_add);
        e.i32c(8);
        e.op(W.i32_add);
        e.get(C.l);
        e.load32(lay.stack_len);
        e.op(W.i32_gt_u);
        e.brIf(0);

        // Nothing fails from here on. The pc of the caller is saved as
        // the step routine would save it.
        e.get(C.l);
        e.load32(lay.frames_ptr);
        e.get(C.depth);
        e.i32c(1);
        e.op(W.i32_sub);
        e.i32c(@sizeOf(Frame));
        e.op(W.i32_mul);
        e.op(W.i32_add);
        e.get(C.pc);
        e.store32(@offsetOf(Frame, "pc"));
        // Missing parameters and the registers above the parameters
        // start nil: t3 runs from the first of them up to t0.
        e.get(C.t3);
        e.get(C.t2);
        e.load8(@offsetOf(Proto, "num_params"));
        e.get(C.t3);
        e.get(C.t2);
        e.load8(@offsetOf(Proto, "num_params"));
        e.op(W.i32_lt_u);
        e.op(W.select);
        e.get(C.t4);
        e.op(W.i32_add);
        e.i32c(4);
        e.op(W.i32_shl);
        e.get(C.l);
        e.load32(lay.stack_ptr);
        e.op(W.i32_add);
        e.set(C.t3);
        e.get(C.t4);
        e.get(C.t2);
        e.load8(@offsetOf(Proto, "max_stack"));
        e.op(W.i32_add);
        e.tee(C.st);
        e.i32c(4);
        e.op(W.i32_shl);
        e.get(C.l);
        e.load32(lay.stack_ptr);
        e.op(W.i32_add);
        e.set(C.t0);
        e.block();
        e.op(W.loop);
        e.op(W.void_type);
        e.inner += 1;
        e.get(C.t3);
        e.get(C.t0);
        e.op(W.i32_ge_u);
        e.brIf(1);
        e.get(C.t3);
        e.i64c(0);
        e.store64(0);
        e.get(C.t3);
        e.i64c(0);
        e.store64(8);
        e.get(C.t3);
        e.i32c(16);
        e.op(W.i32_add);
        e.set(C.t3);
        e.br(0);
        e.op(W.end);
        e.inner -= 1;
        e.end();
        // The stack top is the end of the registers of the callee.
        e.get(C.l);
        e.get(C.st);
        e.store32(@offsetOf(Thread, "top"));
        // t0 = the new frame, written whole.
        e.get(C.l);
        e.load32(lay.frames_ptr);
        e.get(C.l);
        e.load32(lay.frames_len);
        e.tee(C.t3);
        e.i32c(@sizeOf(Frame));
        e.op(W.i32_mul);
        e.op(W.i32_add);
        e.set(C.t0);
        comptime {
            // A frame with every field at its default is all zeros.
            std.debug.assert(@sizeOf(Frame) % 4 == 0);
            const f: Frame = .{ .func = 0, .base = 0, .ret = 0, .want = 0 };
            for (std.mem.asBytes(&f)) |byte| std.debug.assert(byte == 0);
        }
        var off: u32 = 0;
        while (off < @sizeOf(Frame)) : (off += 4) {
            e.get(C.t0);
            e.i32c(0);
            e.store32(off);
        }
        e.get(C.t0);
        e.get(C.t1);
        e.store32(@offsetOf(Frame, "closure"));
        e.get(C.t0);
        e.get(C.t4);
        e.store32(@offsetOf(Frame, "base"));
        e.get(C.t0);
        e.get(C.func);
        e.store32(@offsetOf(Frame, "func"));
        e.get(C.t0);
        e.get(C.func);
        e.store32(@offsetOf(Frame, "ret"));
        e.get(C.t0);
        e.get(C.want);
        e.store32(@offsetOf(Frame, "want"));
        e.get(C.l);
        e.get(C.t3);
        e.i32c(1);
        e.op(W.i32_add);
        e.store32(lay.frames_len);

        // Run the code of the callee, which returns here when it returns.
        // t0 = the code, t1 = the pc it starts at.
        e.get(C.t2);
        e.load32(@offsetOf(Proto, "jit_code"));
        e.set(C.t0);
        e.i32c(0);
        e.set(C.t1);
        e.block(); // returned
        e.op(W.loop);
        e.op(W.void_type);
        e.inner += 1;
        e.u32c(nest);
        e.u32c(nest);
        e.load32(0);
        e.i32c(1);
        e.op(W.i32_add);
        e.store32(0);
        e.get(C.l);
        e.get(C.depth);
        e.get(C.t1);
        e.get(C.t0);
        e.op(W.call_indirect);
        e.out.uleb(sig_code);
        e.out.uleb(0);
        e.set(C.st);
        e.u32c(nest);
        e.u32c(nest);
        e.load32(0);
        e.i32c(1);
        e.op(W.i32_sub);
        e.store32(0);
        e.get(C.st);
        e.i32c(Step.done);
        e.op(W.i32_eq);
        e.brIf(1);
        // A tail call replaced the frame of the callee. The code of the
        // new function runs here too. Anything else is a status for the
        // caller, whose status handler takes "dispatch" to the
        // trampoline.
        e.block(); // leave
        e.get(C.st);
        e.i32c(Step.dispatch);
        e.op(W.i32_ne);
        e.brIf(0);
        e.get(C.l);
        e.load32(lay.frames_len);
        e.get(C.depth);
        e.i32c(1);
        e.op(W.i32_add);
        e.op(W.i32_ne);
        e.brIf(0);
        e.get(C.l);
        e.load32(lay.frames_ptr);
        e.get(C.depth);
        e.i32c(@sizeOf(Frame));
        e.op(W.i32_mul);
        e.op(W.i32_add);
        e.tee(C.t3);
        e.load32(@offsetOf(Frame, "closure"));
        e.tee(C.t0);
        e.op(W.i32_eqz);
        e.brIf(0);
        e.get(C.t0);
        e.load32(@offsetOf(object.Closure, "proto"));
        e.load32(@offsetOf(Proto, "jit_code"));
        e.tee(C.t0);
        e.op(W.i32_eqz);
        e.brIf(0);
        e.get(C.t3);
        e.load32(@offsetOf(Frame, "pc"));
        e.set(C.t1);
        e.br(1);
        e.end(); // leave
        e.get(C.st);
        e.op(W.@"return");
        e.op(W.end); // loop
        e.inner -= 1;
        e.end(); // returned
        // A fixed result count restores the register window of the
        // caller, as `interp.doReturn` does when it returns into a caller
        // above its stop.
        e.get(C.want);
        e.i32c(0);
        e.op(W.i32_ge_s);
        e.ifThen();
        e.get(C.l);
        e.get(C.l);
        e.load32(lay.frames_ptr);
        e.get(C.depth);
        e.i32c(1);
        e.op(W.i32_sub);
        e.i32c(@sizeOf(Frame));
        e.op(W.i32_mul);
        e.op(W.i32_add);
        e.load32(@offsetOf(Frame, "base"));
        e.i32c(e.p.max_stack);
        e.op(W.i32_add);
        e.store32(@offsetOf(Thread, "top"));
        e.end();
        // The callee may have set a hook, which the interpreter runs.
        e.i32c(Step.next);
        e.i32c(Step.interpret);
        e.get(C.l);
        e.load8(@offsetOf(Thread, "hook_mask"));
        e.op(W.i32_eqz);
        e.op(W.select);
        e.op(W.@"return");
        e.end(); // slow
        e.get(C.l);
        e.get(C.ins);
        e.get(C.pc);
        e.get(C.stop);
        e.get(C.depth);
        e.call(@intFromPtr(&callFromCode), sig_call);
        e.op(W.end);

        const failed = e.oom or e.out.oom;
        const body = if (failed) null else e.out.list.toOwnedSlice(e.gpa) catch null;
        e.out.list.deinit(e.gpa);
        e.out = saved;
        return body;
    }

    /// Emits the body of the function and returns it, owned by the
    /// caller.
    fn function(e: *Emitter) ?[]u8 {
        const n = e.n;
        // Only a closure made by this function opens an upvalue on one of
        // its registers, and only these two instructions mark a variable
        // to be closed.
        for (e.p.protos) |child| for (child.upvals) |d| {
            if (d.in_stack and !d.by_value) e.captures = true;
        };
        for (e.p.code) |ins| switch (opc.op(ins)) {
            .tbc, .tforprep => e.closes = true,
            else => {},
        };
        // The frame count, and the frame of this function.
        e.get(L.l);
        e.load32(e.lay.frames_len);
        e.set(L.depth);
        e.loadFrame();

        e.op(W.loop);
        e.op(W.void_type);
        e.block(); // status
        // One block per instruction and one for the end of the code.
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            e.op(W.block);
            e.op(W.void_type);
        }
        e.get(L.pc);
        e.op(W.br_table);
        e.out.uleb(n);
        i = 0;
        while (i <= n) : (i += 1) e.out.uleb(i);
        e.op(W.end);
        e.inner = 0;
        var pc: u32 = 0;
        while (pc < n) : (pc += 1) {
            e.cur = pc;
            e.instruction(pc, e.p.code[pc]);
            std.debug.assert(e.inner == 0);
            e.op(W.end);
        }
        // Execution never runs off the end of a function.
        e.op(W.@"unreachable");
        e.op(W.end); // status
        e.cur = n;
        e.inner = 0;
        e.statusHandler();
        e.op(W.end); // loop
        e.op(W.@"unreachable");
        e.op(W.end); // function

        if (e.oom or e.out.oom) return null;
        const body = e.out.list.toOwnedSlice(e.gpa) catch return null;
        return body;
    }

    /// A step returned a status other than "next" or "skip", which is in
    /// `st`. A step that moved the pc of this frame continues here, and
    /// anything else returns to the trampoline. The handler sits inside
    /// the loop, right after the status block.
    fn statusHandler(e: *Emitter) void {
        // Anything but "dispatch" leaves.
        e.get(L.st);
        e.i32c(Step.dispatch);
        e.op(W.i32_ne);
        e.ifThen();
        e.get(L.st);
        e.op(W.@"return");
        e.end();
        // Another frame on top, or another function in this frame (a
        // tail call), goes to the trampoline.
        e.get(L.l);
        e.load32(e.lay.frames_len);
        e.get(L.depth);
        e.op(W.i32_ne);
        e.ifThen();
        e.i32c(Step.dispatch);
        e.op(W.@"return");
        e.end();
        e.frameAddr();
        e.tee(L.t0);
        e.load32(@offsetOf(Frame, "closure"));
        e.tee(L.t1);
        e.op(W.i32_eqz);
        e.ifThen();
        e.i32c(Step.dispatch);
        e.op(W.@"return");
        e.end();
        e.get(L.t1);
        e.load32(@offsetOf(object.Closure, "proto"));
        e.u32c(@intCast(@intFromPtr(e.p)));
        e.op(W.i32_ne);
        e.ifThen();
        e.i32c(Step.dispatch);
        e.op(W.@"return");
        e.end();
        e.get(L.t0);
        e.load32(@offsetOf(Frame, "pc"));
        e.set(L.pc);
        e.get(L.t0);
        e.load32(@offsetOf(Frame, "base"));
        e.set(L.base);
        e.reloadBp();
        e.br(0);
    }

    // -----------------------------------------------------------------
    // Instructions

    fn instruction(e: *Emitter, pc: u32, ins: u32) void {
        const o = opc.op(ins);
        const ra: u32 = opc.a(ins);
        const rb: u32 = opc.b(ins);
        const rc: u32 = opc.c(ins);
        switch (o) {
            // The operand word of the previous instruction.
            .extraarg => e.op(W.@"unreachable"),

            .move => e.copy16(L.bp, slotOff(ra), L.bp, slotOff(rb)),
            .loadk => e.storeConst(ra, e.p.constants[opc.bx(ins)]),
            .loadi => e.storeConst(ra, Value.int(opc.sbx(ins))),
            .loadf => e.storeConst(ra, Value.float(@floatFromInt(opc.sbx(ins)))),
            .loadfalse => e.storeConst(ra, .false),
            .loadtrue => e.storeConst(ra, .true),
            .loadnil => {
                if (rb > 8) return e.step();
                var i: u32 = 0;
                while (i <= rb) : (i += 1) e.storeConst(ra + i, .nil);
            },

            .getupval => {
                e.upvalLoc(rb);
                e.copy16(L.bp, slotOff(ra), L.t0, 0);
            },
            .setupval => {
                e.upvalLoc(rb);
                e.copy16(L.t0, 0, L.bp, slotOff(ra));
                // The barrier of the upvalue in t1.
                e.get(L.t1);
                e.load8(@offsetOf(gc.Header, "flags"));
                e.i32c(1 << @bitOffsetOf(gc.Header.Flags, "barrier"));
                e.op(W.i32_and);
                e.ifThen();
                e.get(L.l);
                e.get(L.t1);
                e.call(@intFromPtr(&helpers.barrier), sig_barrier);
                e.end();
            },

            .getfield => e.fieldGet(.{ .reg = rb }, rc, ra),
            .gettabup => e.fieldGet(.{ .upval = rb }, rc, ra),
            .setfield => e.fieldSet(.{ .reg = ra }, rb, rc),
            .settabup => e.fieldSet(.{ .upval = ra }, rb, rc),
            .self => e.method(ra, rb, rc),
            .gettable => e.tableGet(ra, rb, rc),
            .settable => e.tableSet(ra, rb, rc),
            .getindex => e.indexGet(ra, rb, rc),
            .len => {
                e.block(); // done
                e.block(); // helper
                e.guardTag(rb, tag_string, 0);
                e.get(L.bp);
                e.get(L.bp);
                e.load32(slotOff(rb));
                e.load32(@offsetOf(object.String, "chars"));
                e.op(W.i64_extend_i32_u);
                e.store64(slotOff(ra));
                e.storeTag(ra, tag_int);
                e.br(1);
                e.end();
                e.regAddr(rb);
                e.regAddr(ra);
                e.call(@intFromPtr(&helpers.length), sig_length);
                e.op(W.i32_eqz);
                e.brIf(0);
                e.step();
                e.end();
            },

            .add => e.arith(.add, ra, .{ .reg = rb }, .{ .reg = rc }),
            .sub => e.arith(.sub, ra, .{ .reg = rb }, .{ .reg = rc }),
            .mul => e.arith(.mul, ra, .{ .reg = rb }, .{ .reg = rc }),
            .div => e.arith(.div, ra, .{ .reg = rb }, .{ .reg = rc }),
            inline .addk, .subk, .mulk, .divk => |ko| {
                const k = e.constOperand(rc) orelse return e.step();
                e.arith(switch (ko) {
                    .addk => .add,
                    .subk => .sub,
                    .mulk => .mul,
                    .divk => .div,
                    else => unreachable,
                }, ra, .{ .reg = rb }, k);
            },
            .addi => e.arith(.add, ra, .{ .reg = rb }, .{ .int = opc.sc(ins) }),
            .modk, .idivk => {
                const k = e.p.constants[rc];
                if (k.tag != .integer or k.asInt() == 0 or k.asInt() == -1) return e.step();
                e.divide(o == .modk, ra, rb, .{ .int = k.asInt() });
            },
            .mod, .idiv => e.divide(o == .mod, ra, rb, .{ .reg = rc }),
            .band, .bor, .bxor => {
                e.block(); // done
                e.block(); // slow
                e.guardTag(rb, tag_int, 0);
                e.guardTag(rc, tag_int, 0);
                e.get(L.bp);
                e.loadInt(.{ .reg = rb });
                e.loadInt(.{ .reg = rc });
                e.op(switch (o) {
                    .band => W.i64_and,
                    .bor => W.i64_or,
                    else => W.i64_xor,
                });
                e.store64(slotOff(ra));
                e.storeTag(ra, tag_int);
                e.br(1);
                e.end();
                e.step();
                e.end();
            },
            .unm => {
                e.block(); // done
                e.block(); // slow
                e.block(); // float
                e.guardTag(rb, tag_int, 0);
                e.get(L.bp);
                e.i64c(0);
                e.loadInt(.{ .reg = rb });
                e.op(W.i64_sub);
                e.store64(slotOff(ra));
                e.storeTag(ra, tag_int);
                e.br(2);
                e.end();
                e.guardTag(rb, tag_float, 0);
                e.get(L.bp);
                e.loadFloat(.{ .reg = rb });
                e.op(W.f64_neg);
                e.mem(W.f64_store, 3, slotOff(ra));
                e.storeTag(ra, tag_float);
                e.br(1);
                e.end();
                e.step();
                e.end();
            },
            .not => {
                // false and true differ only in their tags.
                const f: *const [2]u64 = @ptrCast(&Value.false);
                const t: *const [2]u64 = @ptrCast(&Value.true);
                std.debug.assert(f[0] == t[0]);
                e.get(L.bp);
                e.i64c(@bitCast(f[0]));
                e.store64(slotOff(ra));
                e.get(L.bp);
                e.i64c(@bitCast(f[1]));
                e.i64c(@bitCast(t[1]));
                e.tagOf(rb);
                e.i32c(tag_false);
                e.op(W.i32_gt_u);
                e.op(W.select);
                e.store64(tagOff(ra));
            },

            .jmp => {
                const off = opc.sj(ins);
                const target: u32 = @intCast(@as(i64, pc) + 1 + off);
                if (off < 0) {
                    // A backward jump is a safe point for finalizers,
                    // which the step routine runs.
                    e.block();
                    e.get(L.l);
                    e.load32(e.lay.global);
                    e.load32(e.lay.pending);
                    e.op(W.i32_eqz);
                    e.brIf(0);
                    e.step();
                    e.end();
                }
                e.goto(target);
            },
            .lt => e.compare(.lt, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .le => e.compare(.le, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .eq => e.compare(.eq, .{ .reg = ra }, .{ .reg = rb }, rc != 0),
            .lti => e.compare(.lt, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0),
            .lei => e.compare(.le, .{ .reg = ra }, .{ .int = opc.sb(ins) }, rc != 0),
            .gti => e.compare(.lt, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0),
            .gei => e.compare(.le, .{ .int = opc.sb(ins) }, .{ .reg = ra }, rc != 0),
            .eqk => e.equalConstant(ra, e.p.constants[rb], rc != 0),
            .test_, .testset => {
                if (!e.jumpFollows(pc)) return e.step();
                const r = if (o == .test_) ra else rb;
                // Skip the jump when the truth of the value differs from C.
                e.tagOf(r);
                e.i32c(tag_false);
                e.op(if (rc != 0) W.i32_le_u else W.i32_gt_u);
                e.gotoIf(pc + 2);
                if (o == .testset) e.copy16(L.bp, slotOff(ra), L.bp, slotOff(rb));
            },
            .testnil => {
                if (!e.jumpFollows(pc)) return e.step();
                // Skip the jump when "is nil" differs from C.
                e.tagOf(ra);
                e.i32c(tag_nil);
                e.op(if (rc != 0) W.i32_ne else W.i32_eq);
                e.gotoIf(pc + 2);
            },

            .forloop => {
                // The integer loop: R[A+1] counts the iterations left.
                e.block(); // slow
                e.guardTag(ra, tag_int, 0);
                e.loadInt(.{ .reg = ra + 1 });
                e.tee(L.x0);
                e.op(W.i64_eqz);
                e.gotoIf(pc + 1);
                e.get(L.bp);
                e.get(L.x0);
                e.i64c(1);
                e.op(W.i64_sub);
                e.store64(slotOff(ra + 1));
                e.loadInt(.{ .reg = ra });
                e.loadInt(.{ .reg = ra + 2 });
                e.op(W.i64_add);
                e.set(L.x0);
                e.get(L.bp);
                e.get(L.x0);
                e.store64(slotOff(ra));
                e.get(L.bp);
                e.get(L.x0);
                e.store64(slotOff(ra + 3));
                e.storeTag(ra + 3, tag_int);
                e.goto(pc + 1 - opc.bx(ins));
                e.end();
                e.step();
            },
            .tforloop => {
                e.tagOf(ra + 4);
                e.i32c(tag_nil);
                e.op(W.i32_eq);
                e.gotoIf(pc + 1);
                e.copy16(L.bp, slotOff(ra + 2), L.bp, slotOff(ra + 4));
                e.goto(pc + 1 - opc.bx(ins));
            },

            .call => {
                // The call function of the module makes the call and runs
                // the code of the callee, and reports like a step routine.
                e.get(L.l);
                e.get(L.stop);
                e.get(L.depth);
                e.u32c(pc + 1);
                e.u32c(ins);
                e.get(L.base);
                e.i32c(ra);
                e.op(W.i32_add);
                e.i32c(if (rb != 0) @as(i64, rb) - 1 else -1);
                e.i32c(@as(i64, rc) - 1);
                e.op(W.call);
                e.call_sites.append(e.gpa, @intCast(e.out.list.items.len)) catch {
                    e.oom = true;
                };
                e.out.bytes(&.{ 0x80, 0x80, 0x80, 0x80, 0x00 });
                e.stepResult();
            },
            .ret0 => e.leanReturn(0, ra),
            .ret1 => e.leanReturn(1, ra),

            // An instruction that never changes the pc by itself falls
            // through to its successor.
            else => e.step(),
        }
    }

    /// `ret0` (n = 0) and `ret1` (n = 1) with the result in register
    /// `ra`, for a frame that returns to the caller that called its code
    /// from compiled code, or to the stop of the run. This is the part
    /// of `interp.doReturn` that such a frame needs when it has no
    /// finish action, nothing to close, no hook, and a caller that wants
    /// at most one result. Anything else takes the step routine.
    fn leanReturn(e: *Emitter, n: u32, ra: u32) void {
        const lay = e.lay;
        e.block(); // slow
        e.get(L.l);
        e.load8(@offsetOf(Thread, "hook_mask"));
        e.brIf(0);
        // The frame below is the stop.
        e.get(L.depth);
        e.get(L.stop);
        e.i32c(1);
        e.op(W.i32_add);
        e.op(W.i32_gt_u);
        e.brIf(0);
        e.frameAddr();
        e.tee(L.t0);
        e.load8(@offsetOf(Frame, "boundary"));
        e.brIf(0);
        e.get(L.t0);
        e.load8(@offsetOf(Frame, "finish") + @offsetOf(state.Finish.Packed, "kind"));
        e.brIf(0);
        if (e.captures) {
            e.block();
            e.get(L.l);
            e.load32(@offsetOf(Thread, "open_upvals"));
            e.tee(L.t1);
            e.op(W.i32_eqz);
            e.brIf(0);
            e.get(L.t1);
            e.load32(@offsetOf(object.Upvalue, "level"));
            e.get(L.base);
            e.op(W.i32_ge_u);
            e.brIf(1);
            e.end();
        }
        if (e.closes) {
            e.block();
            e.get(L.l);
            e.load32(lay.tbc_len);
            e.tee(L.t1);
            e.op(W.i32_eqz);
            e.brIf(0);
            e.get(L.l);
            e.load32(lay.tbc_ptr);
            e.get(L.t1);
            e.i32c(2);
            e.op(W.i32_shl);
            e.op(W.i32_add);
            e.i32c(4);
            e.op(W.i32_sub);
            e.load32(0);
            e.get(L.base);
            e.op(W.i32_ge_u);
            e.brIf(1);
            e.end();
        }
        // t1 = the wanted count, which must be at most one.
        e.get(L.t0);
        e.load32(@offsetOf(Frame, "want"));
        e.tee(L.t1);
        e.i32c(1);
        e.op(W.i32_gt_s);
        e.brIf(0);
        // t2 = the return slot, t3 = the count of values stored there.
        e.get(L.t0);
        e.load32(@offsetOf(Frame, "ret"));
        e.set(L.t2);
        e.get(L.t1);
        if (n == 1) {
            // All results (-1) and one result take the value.
            e.i32c(1);
            e.op(W.i32_and);
        } else {
            e.i32c(1);
            e.op(W.i32_eq);
        }
        e.set(L.t3);
        e.get(L.t3);
        e.ifThen();
        // t4 = the address of the return slot.
        e.get(L.l);
        e.load32(lay.stack_ptr);
        e.get(L.t2);
        e.i32c(4);
        e.op(W.i32_shl);
        e.op(W.i32_add);
        e.set(L.t4);
        if (n == 1) {
            e.copy16(L.t4, 0, L.bp, slotOff(ra));
        } else {
            e.get(L.t4);
            e.i64c(0);
            e.store64(0);
            e.get(L.t4);
            e.i64c(0);
            e.store64(8);
        }
        e.end();
        e.get(L.l);
        e.get(L.t2);
        e.get(L.t3);
        e.op(W.i32_add);
        e.store32(@offsetOf(Thread, "top"));
        e.get(L.l);
        e.get(L.depth);
        e.i32c(1);
        e.op(W.i32_sub);
        e.store32(lay.frames_len);
        e.i32c(Step.done);
        e.op(W.@"return");
        e.end();
        e.step();
    }

    /// Branches `depth` out when register `r` holds `tag`.
    fn guardNot(e: *Emitter, r: u32, tag: u8, depth: u32) void {
        e.tagOf(r);
        e.i32c(tag);
        e.op(W.i32_eq);
        e.brIf(depth);
    }

    /// Whether the instruction after `pc` is the jump that every test
    /// instruction is followed by.
    fn jumpFollows(e: *Emitter, pc: u32) bool {
        return pc + 1 < e.p.code.len and opc.op(e.p.code[pc + 1]) == .jmp;
    }

    /// t0 = the address of the value of upvalue `i` of the running
    /// closure, and t1 = the upvalue.
    fn upvalLoc(e: *Emitter, i: u32) void {
        // The closure is the value below register 0.
        e.get(L.bp);
        e.i32c(16);
        e.op(W.i32_sub);
        e.load32(0);
        e.load32(@intCast(@sizeOf(object.Closure) + i * @sizeOf(usize)));
        e.tee(L.t1);
        e.load32(@offsetOf(object.Upvalue, "loc"));
        e.set(L.t0);
    }

    /// Pushes the address of register `r`.
    fn regAddr(e: *Emitter, r: u32) void {
        e.get(L.bp);
        if (r != 0) {
            e.u32c(slotOff(r));
            e.op(W.i32_add);
        }
    }

    /// Pushes the address of a value.
    fn placeAddr(e: *Emitter, pl: Place) void {
        switch (pl) {
            .reg => |r| e.regAddr(r),
            .konst => |k| e.u32c(@intCast(@intFromPtr(&e.p.constants[k]))),
            .upval => |i| {
                e.upvalLoc(i);
                e.get(L.t0);
            },
        }
    }

    /// R[dst] = x op y. Integer operands, then float operands, run
    /// inline, and anything else runs the step routine. A float constant
    /// or a division tries floats first.
    fn arith(e: *Emitter, op_: ArithOp, dst: u32, x: Operand, y: Operand) void {
        e.block(); // done
        e.block(); // slow
        const floats_first = y == .float or op_ == .div;
        if (!floats_first) {
            e.block(); // not integers
            e.guard(x, tag_int, 0);
            e.guard(y, tag_int, 0);
            e.get(L.bp);
            e.loadInt(x);
            e.loadInt(y);
            e.op(switch (op_) {
                .add => W.i64_add,
                .sub => W.i64_sub,
                .mul => W.i64_mul,
                .div => unreachable,
            });
            e.store64(slotOff(dst));
            e.storeTag(dst, tag_int);
            e.br(2);
            e.end();
            e.guard(x, tag_float, 0);
            e.guard(y, tag_float, 0);
            e.floatArith(op_, dst, x, y, false);
            e.br(1);
        } else {
            e.block(); // not floats
            e.guard(x, tag_float, 0);
            e.guard(y, tag_float, 0);
            e.floatArith(op_, dst, x, y, false);
            e.br(2);
            e.end();
            if (op_ == .div and y != .float) {
                // Division converts two integers.
                e.guard(x, tag_int, 0);
                e.guard(y, tag_int, 0);
                e.floatArith(op_, dst, x, y, true);
                e.br(1);
            } else e.br(0);
        }
        e.end();
        e.step();
        e.end();
    }

    fn floatArith(e: *Emitter, op_: ArithOp, dst: u32, x: Operand, y: Operand, from_ints: bool) void {
        e.get(L.bp);
        if (from_ints) {
            e.loadIntAsFloat(x);
            e.loadIntAsFloat(y);
        } else {
            e.loadFloat(x);
            e.loadFloat(y);
        }
        e.op(switch (op_) {
            .add => W.f64_add,
            .sub => W.f64_sub,
            .mul => W.f64_mul,
            .div => W.f64_div,
        });
        e.mem(W.f64_store, 3, slotOff(dst));
        e.storeTag(dst, tag_float);
    }

    /// R[dst] = R[x] % y or R[x] // y for integers, with the rounding
    /// toward minus infinity of `ops.imod` and `ops.idiv`. A divisor of
    /// zero or minus one takes the step routine, which raises the error
    /// or avoids the overflow.
    fn divide(e: *Emitter, mod: bool, dst: u32, x: u32, y: Operand) void {
        e.block(); // done
        e.block(); // slow
        e.guardTag(x, tag_int, 0);
        e.guard(y, tag_int, 0);
        e.loadInt(y);
        e.set(L.x1);
        if (y == .reg) {
            e.get(L.x1);
            e.op(W.i64_eqz);
            e.brIf(0);
            e.get(L.x1);
            e.i64c(-1);
            e.op(W.i64_eq);
            e.brIf(0);
        }
        e.loadInt(.{ .reg = x });
        e.set(L.x0);
        // x2 = the remainder truncated toward zero.
        e.get(L.x0);
        e.get(L.x1);
        e.op(W.i64_rem_s);
        e.set(L.x2);
        if (!mod) {
            e.get(L.x0);
            e.get(L.x1);
            e.op(W.i64_div_s);
            e.set(L.x0);
        }
        // The truncated results are right unless the remainder is not
        // zero and its sign differs from the sign of the divisor.
        e.get(L.x2);
        e.i64c(0);
        e.op(W.i64_ne);
        e.get(L.x2);
        e.get(L.x1);
        e.op(W.i64_xor);
        e.i64c(0);
        e.op(W.i64_lt_s);
        e.op(W.i32_and);
        e.ifThen();
        if (mod) {
            e.get(L.x2);
            e.get(L.x1);
            e.op(W.i64_add);
            e.set(L.x2);
        } else {
            e.get(L.x0);
            e.i64c(1);
            e.op(W.i64_sub);
            e.set(L.x0);
        }
        e.end();
        e.get(L.bp);
        e.get(if (mod) L.x2 else L.x0);
        e.store64(slotOff(dst));
        e.storeTag(dst, tag_int);
        e.br(1);
        e.end();
        e.step();
        e.end();
    }

    /// A comparison that skips the following jump when its result
    /// differs from `k`, and otherwise continues into that jump.
    fn compare(e: *Emitter, op_: CompareOp, x: Operand, y: Operand, k: bool) void {
        const pc = e.cur;
        if (!e.jumpFollows(pc)) return e.step();
        e.block(); // slow
        e.block(); // not integers
        e.guard(x, tag_int, 0);
        e.guard(y, tag_int, 0);
        e.loadInt(x);
        e.loadInt(y);
        e.op(switch (op_) {
            .lt => W.i64_lt_s,
            .le => W.i64_le_s,
            .eq => W.i64_eq,
        });
        if (k) e.op(W.i32_eqz);
        e.gotoIf(pc + 2);
        e.goto(pc + 1);
        e.end();
        e.guard(x, tag_float, 0);
        e.guard(y, tag_float, 0);
        e.loadFloat(x);
        e.loadFloat(y);
        e.op(switch (op_) {
            .lt => W.f64_lt,
            .le => W.f64_le,
            .eq => W.f64_eq,
        });
        if (k) e.op(W.i32_eqz);
        e.gotoIf(pc + 2);
        e.goto(pc + 1);
        e.end();
        e.step();
    }

    /// R[x] == K, for the constants whose equality the tag and the
    /// payload decide.
    fn equalConstant(e: *Emitter, x: u32, k: Value, c: bool) void {
        const pc = e.cur;
        if (!e.jumpFollows(pc)) return e.step();
        switch (k.tag) {
            .integer => {
                // Another number type compares in the step routine.
                e.block();
                e.guardTag(x, tag_int, 0);
                e.loadInt(.{ .reg = x });
                e.i64c(k.asInt());
                // Skip when the result differs from C.
                e.op(if (c) W.i64_ne else W.i64_eq);
                e.gotoIf(pc + 2);
                e.goto(pc + 1);
                e.end();
                e.step();
            },
            .nil, .false, .true => {
                e.tagOf(x);
                e.i32c(@backingInt(k.tag));
                e.op(if (c) W.i32_ne else W.i32_eq);
                e.gotoIf(pc + 2);
            },
            .string => {
                // Two interned strings are equal exactly when they are
                // the same object, and a string that is not interned is
                // longer than any interned one.
                if (!k.as(object.String).flags.interned) return e.step();
                // equal = tag is string and payload matches
                e.tagOf(x);
                e.i32c(tag_string);
                e.op(W.i32_eq);
                e.get(L.bp);
                e.load64(slotOff(x));
                e.i64c(@bitCast(k.payload));
                e.op(W.i64_eq);
                e.op(W.i32_and);
                if (c) e.op(W.i32_eqz);
                e.gotoIf(pc + 2);
            },
            else => e.step(),
        }
    }

    // -----------------------------------------------------------------
    // Table accesses
    //
    // The inline paths are the hit paths of `interp.fast`, as in the
    // native backends. Every other case calls the helper that runs the
    // whole fast path of the interpreter, and then the step routine.

    /// t0 = the table at `t`. Branches `depth` out when the value there
    /// is something else.
    fn loadTable(e: *Emitter, t: Place, depth: u32) void {
        switch (t) {
            .reg => |r| {
                e.guardTag(r, tag_table, depth);
                e.get(L.bp);
                e.load32(slotOff(r));
                e.set(L.t0);
            },
            .upval => |i| {
                e.upvalLoc(i);
                e.get(L.t0);
                e.load8(@intCast(tl.value_tag));
                e.i32c(tag_table);
                e.op(W.i32_ne);
                e.brIf(depth);
                e.get(L.t0);
                e.load32(0);
                e.set(L.t0);
            },
            .konst => unreachable,
        }
    }

    /// `node` = the hash node of the table in `tab` that the slot
    /// prediction at `slot_addr` names. Branches `depth` out when the
    /// table has no such node or the node holds another key than the
    /// string `key`. This is the test that `interp.lookupIc` makes before
    /// it trusts a prediction.
    fn predictedNode(e: *Emitter, slot_addr: usize, tab: u32, key: *object.String, node: u32, depth: u32) void {
        e.u32c(@intCast(slot_addr));
        e.mem(W.i32_load16_u, 1, 0);
        e.tee(node);
        e.get(tab);
        e.load32(e.lay.hash_len);
        e.op(W.i32_ge_u);
        e.brIf(depth);
        e.get(tab);
        e.load32(e.lay.hash_ptr);
        e.get(node);
        e.i32c(tl.node_shift);
        e.op(W.i32_shl);
        e.op(W.i32_add);
        e.tee(node);
        e.load64(@intCast(tl.node_key));
        e.i64c(@intCast(@intFromPtr(key)));
        e.op(W.i64_ne);
        e.brIf(depth);
        e.get(node);
        e.load8(@intCast(tl.node_key + tl.value_tag));
        e.i32c(tag_string);
        e.op(W.i32_ne);
        e.brIf(depth);
    }

    fn prediction(e: *Emitter, comptime offset: usize) usize {
        return @intFromPtr(&e.p.ic[e.cur]) + offset;
    }

    /// Branches `depth` out unless a store into the table in `tab` is a
    /// raw store: the table is writable and has no metatable, or one known
    /// to lack `__newindex`. Uses t2.
    fn guardRawStore(e: *Emitter, tab: u32, depth: u32) void {
        e.get(tab);
        e.load8(@intCast(tl.readonly));
        e.brIf(depth);
        e.block();
        e.get(tab);
        e.load32(@intCast(tl.metatable));
        e.tee(L.t2);
        e.op(W.i32_eqz);
        e.brIf(0);
        e.get(L.t2);
        e.load8(@intCast(tl.tm_absent + il.absent_newindex / 8));
        e.i32c(@as(u8, 1) << @intCast(il.absent_newindex % 8));
        e.op(W.i32_and);
        e.op(W.i32_eqz);
        e.brIf(depth + 1);
        e.end();
    }

    /// The write barrier after a store of register `v` into the table in
    /// t0: nothing for a value that is not collectable, and otherwise the
    /// test of the barrier bit, with the slow part in a helper.
    fn tableBarrier(e: *Emitter, v: u32) void {
        e.tagOf(v);
        e.i32c(tag_string);
        e.op(W.i32_ge_u);
        e.get(L.t0);
        e.load8(@intCast(tl.flags));
        e.i32c(@as(u8, 1) << tl.barrier_bit);
        e.op(W.i32_and);
        e.op(W.i32_and);
        e.ifThen();
        e.get(L.l);
        e.get(L.t0);
        e.i32c(0);
        e.regAddr(v);
        e.call(@intFromPtr(&helpers.barrierTable), sig_barrier_table);
        e.end();
    }

    /// Calls `getStr` or `setStr` with the inline cache of the current
    /// instruction, and continues at `done_depth` out when it completed
    /// the instruction.
    fn tableHelper(e: *Emitter, helper: usize, t: Place, key: Place, v: Place, done_depth: u32) void {
        e.get(L.l);
        e.placeAddr(t);
        e.placeAddr(key);
        e.u32c(@intCast(@intFromPtr(&e.p.ic[e.cur])));
        e.placeAddr(v);
        e.call(helper, sig_str);
        e.op(W.i32_eqz);
        e.brIf(done_depth);
    }

    /// R[dst] = t[K[kc]] for a constant string key.
    fn fieldGet(e: *Emitter, t: Place, kc: u32, dst: u32) void {
        e.block(); // done
        e.block(); // miss
        e.loadTable(t, 0);
        e.predictedNode(e.prediction(il.ic_own), L.t0, e.p.constants[kc].as(object.String), L.t1, 0);
        // A nil value may have an `__index` to follow.
        e.get(L.t1);
        e.load8(@intCast(tl.node_val + tl.value_tag));
        e.i32c(tag_nil);
        e.op(W.i32_eq);
        e.brIf(0);
        e.copy16(L.bp, slotOff(dst), L.t1, @intCast(tl.node_val));
        e.br(1);
        e.end();
        e.tableHelper(@intFromPtr(&helpers.getStr), t, .{ .konst = kc }, .{ .reg = dst }, 0);
        e.step();
        e.end();
    }

    /// t[K[kb]] = R[v] for a constant string key.
    fn fieldSet(e: *Emitter, t: Place, kb: u32, v: u32) void {
        e.block(); // done
        e.block(); // miss
        e.loadTable(t, 0);
        e.guardRawStore(L.t0, 0);
        e.predictedNode(e.prediction(il.ic_own), L.t0, e.p.constants[kb].as(object.String), L.t1, 0);
        e.copy16(L.t1, @intCast(tl.node_val), L.bp, slotOff(v));
        e.get(L.t0);
        e.i32c(0);
        e.mem(W.i32_store16, 1, @intCast(tl.tm_absent));
        e.tableBarrier(v);
        e.br(1);
        e.end();
        e.tableHelper(@intFromPtr(&helpers.setStr), t, .{ .konst = kb }, .{ .reg = v }, 0);
        e.step();
        e.end();
    }

    /// R[ra + 1] = R[rb] and R[ra] = R[rb][K[kc]], the lookup of a
    /// method. A receiver that holds the method itself runs inline, and
    /// the helper follows `__index`.
    fn method(e: *Emitter, ra: u32, rb: u32, kc: u32) void {
        e.copy16(L.bp, slotOff(ra + 1), L.bp, slotOff(rb));
        e.block(); // done
        e.block(); // miss
        e.loadTable(.{ .reg = rb }, 0);
        e.predictedNode(e.prediction(il.ic_own), L.t0, e.p.constants[kc].as(object.String), L.t1, 0);
        e.get(L.t1);
        e.load8(@intCast(tl.node_val + tl.value_tag));
        e.i32c(tag_nil);
        e.op(W.i32_eq);
        e.brIf(0);
        e.copy16(L.bp, slotOff(ra), L.t1, @intCast(tl.node_val));
        e.br(1);
        e.end();
        e.tableHelper(@intFromPtr(&helpers.getStr), .{ .reg = ra + 1 }, .{ .konst = kc }, .{ .reg = ra }, 0);
        e.step();
        e.end();
    }

    /// Branches `depth` out unless x0, a zero-based index, is inside the
    /// array part of the table in t0. Leaves the element kind in t2 and
    /// the array in t1.
    fn arrayPart(e: *Emitter, depth: u32) void {
        // An index below one wrapped around to a large unsigned number.
        e.get(L.x0);
        e.get(L.t0);
        e.load32(@intCast(tl.asize));
        e.op(W.i64_extend_i32_u);
        e.op(W.i64_ge_u);
        e.brIf(depth);
        e.get(L.t0);
        e.load32(@intCast(tl.array_ptr));
        e.set(L.t1);
        e.get(L.t0);
        e.load8(@intCast(tl.kind));
        e.set(L.t2);
    }

    /// t1 = the address of element x0 of the array in t1, whose elements
    /// are `1 << shift` bytes.
    fn elementAddr(e: *Emitter, shift: u6) void {
        e.get(L.t1);
        e.get(L.x0);
        e.op(W.i32_wrap_i64);
        e.i32c(shift);
        e.op(W.i32_shl);
        e.op(W.i32_add);
        e.set(L.t1);
    }

    /// R[dst] = element x0 of the table in t0. Branches `miss` out for an
    /// index outside the array part and for a slot that holds nil, which
    /// may have an `__index` to follow, and `done` out on success.
    fn arrayGet(e: *Emitter, dst: u32, miss: u32, done: u32) void {
        e.arrayPart(miss);
        e.block(); // boxed
        e.get(L.t2);
        e.i32c(tl.kind_boxed);
        e.op(W.i32_eq);
        e.brIf(0);
        // An unboxed slot is the payload, and the kind is its tag.
        e.elementAddr(tl.word_shift);
        e.get(L.t1);
        e.load64(0);
        e.tee(L.x1);
        e.i64c(@bitCast(tl.nil_word));
        e.op(W.i64_eq);
        e.brIf(miss + 1);
        e.get(L.bp);
        e.get(L.x1);
        e.store64(slotOff(dst));
        e.get(L.bp);
        e.get(L.t2);
        e.op(W.i64_extend_i32_u);
        e.store64(tagOff(dst));
        e.br(done + 1);
        e.end();
        e.elementAddr(tl.value_shift);
        e.get(L.t1);
        e.load8(@intCast(tl.value_tag));
        e.i32c(tag_nil);
        e.op(W.i32_eq);
        e.brIf(miss);
        e.copy16(L.bp, slotOff(dst), L.t1, 0);
        e.br(done);
    }

    /// R[ra] = R[rb][R[rc]].
    fn tableGet(e: *Emitter, ra: u32, rb: u32, rc: u32) void {
        e.block(); // done
        e.block(); // step
        e.block(); // string key
        e.guardTag(rb, tag_table, 1);
        e.guardTag(rc, tag_int, 0);
        e.get(L.bp);
        e.load32(slotOff(rb));
        e.set(L.t0);
        e.loadInt(.{ .reg = rc });
        e.i64c(1);
        e.op(W.i64_sub);
        e.set(L.x0);
        e.arrayGet(ra, 1, 2);
        e.end();
        e.guardTag(rc, tag_string, 0);
        e.tableHelper(@intFromPtr(&helpers.getStr), .{ .reg = rb }, .{ .reg = rc }, .{ .reg = ra }, 1);
        e.end();
        e.step();
        e.end();
    }

    /// R[ra] = R[rb][c] for a constant integer key.
    fn indexGet(e: *Emitter, ra: u32, rb: u32, c: u32) void {
        // Index zero is never in the array part.
        if (c == 0) return e.step();
        e.block(); // done
        e.block(); // step
        e.guardTag(rb, tag_table, 0);
        e.get(L.bp);
        e.load32(slotOff(rb));
        e.set(L.t0);
        e.i64c(c - 1);
        e.set(L.x0);
        e.arrayGet(ra, 0, 1);
        e.end();
        e.step();
        e.end();
    }

    /// R[ra][R[rb]] = R[rc], as `table.arrayStoreFast` does when the
    /// value fits the kind of the array part.
    fn tableSet(e: *Emitter, ra: u32, rb: u32, rc: u32) void {
        e.block(); // done
        e.block(); // step
        e.block(); // string key
        e.guardTag(ra, tag_table, 1);
        e.guardTag(rb, tag_int, 0);
        e.get(L.bp);
        e.load32(slotOff(ra));
        e.set(L.t0);
        e.loadInt(.{ .reg = rb });
        e.i64c(1);
        e.op(W.i64_sub);
        e.set(L.x0);
        e.arrayPart(1);
        e.guardRawStore(L.t0, 1);
        // guardRawStore used t2, so the kind is read again.
        e.get(L.t0);
        e.load8(@intCast(tl.kind));
        e.set(L.t2);
        e.block(); // boxed
        e.get(L.t2);
        e.i32c(tl.kind_boxed);
        e.op(W.i32_eq);
        e.brIf(0);
        // An unboxed part takes a number of its own kind whose bits are
        // not the nil word. Anything else changes the part or writes the
        // nil word, which the step routine does.
        e.get(L.t2);
        e.tagOf(rc);
        e.op(W.i32_ne);
        e.brIf(2);
        e.get(L.t2);
        e.i32c(tl.kind_none);
        e.op(W.i32_eq);
        e.brIf(2);
        e.loadInt(.{ .reg = rc });
        e.tee(L.x1);
        e.i64c(@bitCast(tl.nil_word));
        e.op(W.i64_eq);
        e.brIf(2);
        e.elementAddr(tl.word_shift);
        e.get(L.t1);
        e.get(L.x1);
        e.store64(0);
        e.br(3);
        e.end();
        e.elementAddr(tl.value_shift);
        e.copy16(L.t1, 0, L.bp, slotOff(rc));
        e.tableBarrier(rc);
        e.br(2);
        e.end();
        e.guardTag(rb, tag_string, 0);
        e.tableHelper(@intFromPtr(&helpers.setStr), .{ .reg = ra }, .{ .reg = rb }, .{ .reg = rc }, 1);
        e.end();
        e.step();
        e.end();
    }
};
