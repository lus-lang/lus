//! Root of the Lus runtime library.

pub const syntax = struct {
    pub const token = @import("syntax/token.zig");
    pub const lexer = @import("syntax/lexer.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const parser = @import("syntax/parser.zig");
    pub const astexport = @import("syntax/astexport.zig");
    pub const format = @import("syntax/format.zig");
    pub const resolve = @import("syntax/resolve.zig");
    pub const doccomment = @import("syntax/doccomment.zig");
    pub const lint = @import("syntax/lint.zig");
};

pub const vm = struct {
    pub const value = @import("vm/value.zig");
    pub const object = @import("vm/object.zig");
    pub const gc = @import("vm/gc.zig");
    pub const state = @import("vm/state.zig");
    pub const table = @import("vm/table.zig");
    pub const wtf8 = @import("vm/wtf8.zig");
    pub const numeric = @import("vm/numeric.zig");
    pub const ops = @import("vm/ops.zig");
    pub const interp = @import("vm/interp.zig");
    pub const debug = @import("vm/debug.zig");
    pub const pledge = @import("vm/pledge.zig");
};

pub const api = @import("api.zig");
pub const bundle = @import("bundle.zig");
pub const tools = @import("tools.zig");

pub const lib = struct {
    pub const aux = @import("lib/aux.zig");
    pub const base = @import("lib/base.zig");
    pub const out = @import("lib/out.zig");
    pub const package = @import("lib/package.zig");
};

pub const compile = struct {
    pub const codegen = @import("compile/codegen.zig");
    pub const opcodes = @import("compile/opcodes.zig");
    pub const disasm = @import("compile/disasm.zig");
    pub const dump = @import("compile/dump.zig");
    pub const feedback = @import("compile/feedback.zig");
};

test {
    _ = syntax.token;
    _ = syntax.lexer;
    _ = syntax.parser;
    _ = syntax.astexport;
    _ = syntax.format;
    _ = syntax.resolve;
    _ = syntax.doccomment;
    _ = syntax.lint;
    _ = vm.value;
    _ = vm.object;
    _ = vm.gc;
    _ = vm.state;
    _ = vm.table;
    _ = vm.wtf8;
    _ = vm.numeric;
    _ = vm.ops;
    _ = vm.interp;
    _ = vm.pledge;
    _ = @import("jit/jit.zig");
    _ = @import("vm/heapcount.zig");
    _ = @import("fuzz.zig");
    _ = compile.opcodes;
    _ = compile.codegen;
    _ = compile.feedback;
    _ = @import("tools/compile.zig");
    _ = api;
    _ = bundle;
    _ = @import("tools/build.zig");
    _ = @import("tools/debug.zig");
    _ = @import("tools/dap.zig");
    _ = @import("lib/init.zig");
}
