//! Code generation for query expressions. Filled in with the language
//! extensions in M3.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const codegen = @import("codegen.zig");

pub fn queryExpr(fs: *codegen.Internal.FS, q: *ast.Query, v: *codegen.Internal.Exp) codegen.Error!void {
    _ = q;
    _ = v;
    return fs.c.err(fs.line, "queries are not supported yet", .{});
}
