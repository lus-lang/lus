//! Root of the Lus runtime library.

const std = @import("std");

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

/// Whether this build has the parser and the compiler. The runtime of
/// executables compiled ahead of time has neither.
pub const has_compiler = @import("build_options").compiler;

pub const vm = struct {
    pub const value = @import("vm/value.zig");
    pub const object = @import("vm/object.zig");
    pub const gc = @import("vm/gc.zig");
    pub const state = @import("vm/state.zig");
    pub const heapcount = @import("vm/heapcount.zig");
    pub const radix = @import("vm/radix.zig");
    pub const faultio = @import("vm/faultio.zig");
    /// Set by `-Dcoverage=true` (`coverage.zig`).
    pub const coverage_enabled = @import("build_options").coverage;
    pub const table = @import("vm/table.zig");
    pub const wtf8 = @import("vm/wtf8.zig");
    pub const numeric = @import("vm/numeric.zig");
    pub const ops = @import("vm/ops.zig");
    pub const interp = @import("vm/interp.zig");
    pub const opprofile = @import("vm/opprofile.zig");
    pub const debug = @import("vm/debug.zig");
    pub const pledge = @import("vm/pledge.zig");
};

/// Edge coverage, in a `-Dcoverage=true` build.
pub const coverage = if (vm.coverage_enabled) @import("coverage.zig") else struct {};

pub const api = @import("api.zig");
pub const bundle = @import("bundle.zig");
pub const tools = @import("tools.zig");
pub const semver = @import("semver.zig");
pub const httpc = @import("httpc.zig");
pub const signed = @import("signed.zig");
pub const modtree = @import("modtree.zig");
pub const remote = @import("remote.zig");
pub const home = @import("home.zig");

pub const lib = struct {
    pub const aux = @import("lib/auxlib.zig");
    pub const base = @import("lib/base.zig");
    pub const out = @import("lib/out.zig");
    pub const package = @import("lib/package.zig");
    pub const term = @import("lib/term.zig");
    pub const serve = @import("lib/serve.zig");
    pub const crypto = @import("lib/crypto.zig");
};

pub const compile = struct {
    pub const codegen = @import("compile/codegen.zig");
    pub const opcodes = @import("compile/opcodes.zig");
    pub const disasm = @import("compile/disasm.zig");
    pub const dump = @import("compile/dump.zig");
};

/// The environment as `coverage.zig` reads it, for the unit tests, which
/// have no `std.process.Init`.
const CEnv = struct {
    pub fn get(_: CEnv, name: []const u8) ?[]const u8 {
        var buf: [64]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
        return std.mem.span(std.c.getenv(z) orelse return null);
    }
};

// The first test of the unit tests. In a coverage build it writes the edges
// of the run to `LUS_COVERAGE` when the tests end, as `lus` does. With
// `LUS_COVERAGE_REPORT` set, the binary prints the report of those files
// and exits, as `lus` does, so the export of the unit tests can merge with
// the report of the shipped build.
test "coverage of the unit tests" {
    if (!vm.coverage_enabled) return;
    const env: CEnv = .{};
    if (env.get("LUS_COVERAGE_REPORT")) |dir| {
        const status = try coverage.report(std.testing.io, std.heap.page_allocator, dir, env);
        std.process.exit(status);
    }
    if (env.get("LUS_COVERAGE")) |d| coverage.setupDir(d);
}

test {
    _ = lib.serve;
    _ = semver;
    _ = httpc;
    _ = signed;
    _ = modtree;
    _ = remote;
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
    _ = @import("vm/radix.zig");
    _ = @import("vm/inv.zig");
    _ = @import("vm/sched.zig");
    _ = @import("fuzz.zig");
    _ = @import("compile/sweep.zig");
    _ = @import("vm/sweep.zig");
    _ = @import("fuzzlib.zig");
    if (@import("build_options").net) _ = @import("fuzztls.zig");
    _ = compile.opcodes;
    _ = compile.codegen;
    _ = @import("tools/compile.zig");
    _ = api;
    _ = bundle;
    _ = @import("tools/build.zig");
    _ = @import("tools/libproof.zig");
    _ = @import("link/lobj.zig");
    _ = @import("link/link.zig");
    _ = @import("link/macho.zig");
    _ = @import("link/pe.zig");
    _ = @import("link/elfdyn.zig");
    _ = @import("tools/debug.zig");
    _ = @import("tools/dap.zig");
    _ = @import("tools/help.zig");
    _ = @import("tools/agents.zig");
    _ = @import("tools/tree.zig");
    _ = @import("syntax/explain.zig");
    _ = @import("syntax/suppress.zig");
    _ = @import("syntax/fix.zig");
    _ = @import("tools/test.zig");
    _ = @import("tools/lsp.zig");
    _ = @import("tools/doc_html.zig");
    _ = @import("tools/paths.zig");
    _ = @import("lib/init.zig");
    _ = @import("lib/shell.zig");
    _ = @import("lib/glob.zig");
    _ = @import("lib/process.zig");
    _ = @import("lib/watch.zig");
}
