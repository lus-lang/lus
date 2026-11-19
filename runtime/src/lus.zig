//! Root of the Lus runtime library.

pub const syntax = struct {
    pub const token = @import("syntax/token.zig");
    pub const lexer = @import("syntax/lexer.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const parser = @import("syntax/parser.zig");
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
};

pub const compile = struct {
    pub const opcodes = @import("compile/opcodes.zig");
};

test {
    _ = syntax.token;
    _ = syntax.lexer;
    _ = syntax.parser;
    _ = vm.value;
    _ = vm.object;
    _ = vm.gc;
    _ = vm.state;
    _ = vm.table;
    _ = vm.wtf8;
    _ = vm.numeric;
    _ = vm.ops;
    _ = vm.interp;
    _ = compile.opcodes;
}
