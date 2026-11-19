//! The syntax tree. It is purely syntactic: names are unresolved, groups
//! look like ordinary field paths, and every node keeps its source span so
//! the formatter, the linter, and the language server can work from it.
//! The resolver annotates bindings in side tables.

const std = @import("std");
const token = @import("token.zig");
pub const Span = token.Span;

pub const Name = struct {
    text: []const u8,
    span: Span,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    band,
    bor,
    bxor,
    shl,
    shr,

    /// Left and right priorities (section 3 of the grammar).
    pub fn priority(op: BinOp) struct { u8, u8 } {
        return switch (op) {
            .@"or" => .{ 1, 1 },
            .@"and" => .{ 2, 2 },
            .lt, .gt, .le, .ge, .ne, .eq => .{ 3, 3 },
            .bor => .{ 4, 4 },
            .bxor => .{ 5, 5 },
            .band => .{ 6, 6 },
            .shl, .shr => .{ 7, 7 },
            .concat => .{ 9, 8 },
            .add, .sub => .{ 10, 10 },
            .mul, .div, .idiv, .mod => .{ 11, 11 },
            .pow => .{ 14, 13 },
        };
    }

    pub fn symbol(op: BinOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .idiv => "//",
            .mod => "%",
            .pow => "^",
            .concat => "..",
            .eq => "==",
            .ne => "~=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .@"and" => "and",
            .@"or" => "or",
            .band => "&",
            .bor => "|",
            .bxor => "~",
            .shl => "<<",
            .shr => ">>",
        };
    }
};

pub const unary_priority = 12;

pub const UnOp = enum {
    neg,
    not,
    len,
    bnot,

    pub fn symbol(op: UnOp) []const u8 {
        return switch (op) {
            .neg => "-",
            .not => "not ",
            .len => "#",
            .bnot => "~",
        };
    }
};

pub const Expr = struct {
    span: Span,
    line: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        nil,
        true,
        false,
        vararg,
        integer: i64,
        float: f64,
        /// Digits of a bigint literal (without the `n` suffix).
        bigint: []const u8,
        /// Text of a decimal literal (without the `d` suffix).
        decimal: []const u8,
        string: []const u8,
        interp: []InterpPart,
        function: *Function,
        table: []Field,
        binop: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
        unop: struct { op: UnOp, operand: *Expr },
        name: Name,
        paren: *Expr,
        /// `obj.name` (dot) or `obj[key]`.
        index: struct { obj: *Expr, key: *Expr, dot: bool },
        call: struct { callee: *Expr, args: []*Expr, args_kind: ArgsKind },
        method: struct { obj: *Expr, name: Name, args: []*Expr, args_kind: ArgsKind },
        /// `obj[from, to]`. Omitted bounds are null.
        slice: struct { obj: *Expr, from: ?*Expr, to: ?*Expr },
        /// `expr?`: short-circuits the rest of the enclosing chain when the
        /// value is nil or false. `chain` marks the outermost node of a
        /// suffix chain containing at least one `?`.
        optional: *Expr,
        /// Outermost node of a suffix chain that contains a `?`.
        chain: *Expr,
        catch_: Catch,
        do_: *Block,
        enum_: []Name,
        query: *Query,
    };
};

pub const ArgsKind = enum { parens, table, string };

pub const InterpPart = union(enum) {
    text: []const u8,
    expr: *Expr,
};

pub const Catch = struct {
    handler: ?*Expr,
    body: *Expr,
};

pub const Field = struct {
    kind: union(enum) {
        positional: *Expr,
        named: struct { name: Name, value: *Expr },
        keyed: struct { key: *Expr, value: *Expr },
    },
};

pub const Function = struct {
    params: []Name,
    is_vararg: bool,
    /// Name of the vararg table parameter (`...t`), if any.
    vararg_name: ?Name = null,
    /// Implicit `self` parameter (method definitions).
    is_method: bool = false,
    body: *Block,
    line: u32,
    end_line: u32,
    span: Span,
    /// Debug name, when known from the definition site.
    name: ?[]const u8 = null,
};

/// An attribute in `<...>`. Compile-time attributes are keywords, runtime
/// attributes are expressions.
pub const Attrib = union(enum) {
    @"const",
    close,
    group,
    runtime: *Expr,
};

pub const AttName = struct {
    name: Name,
    attribs: []Attrib = &.{},

    pub fn has(a: AttName, comptime which: std.meta.Tag(Attrib)) bool {
        for (a.attribs) |at| if (at == which) return true;
        return false;
    }
};

pub const Block = struct {
    stats: []*Stat,
    span: Span,
    end_line: u32,
};

pub const Stat = struct {
    span: Span,
    line: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        empty,
        expr: *Expr, // a call
        local: struct { names: []AttName, values: []*Expr },
        local_from: struct { names: []AttName, source: *Expr },
        /// `local g <group> = {...}` (and copies). Values are group
        /// constructors or names of other groups.
        local_group: struct { names: []AttName, inits: []GroupInit },
        local_function: struct { name: Name, func: *Function },
        global: struct { default_attribs: []Attrib, names: []AttName, values: ?[]*Expr, star: bool },
        global_from: struct { default_attribs: []Attrib, names: []AttName, source: *Expr },
        global_function: struct { name: Name, func: *Function },
        assign: struct { targets: []*Expr, values: []*Expr },
        assign_from: struct { targets: []*Expr, source: *Expr },
        function: struct { path: []Name, method: ?Name, func: *Function },
        do_: *Block,
        while_: struct { cond: Cond, body: *Block },
        repeat_: struct { body: *Block, cond: *Expr },
        if_: struct { clauses: []IfClause, else_: ?*Block },
        numeric_for: struct { name: Name, start: *Expr, limit: *Expr, step: ?*Expr, body: *Block },
        generic_for: struct { names: []Name, exprs: []*Expr, body: *Block },
        return_: []*Expr,
        provide: []*Expr,
        break_,
        continue_,
        goto_: Name,
        label: Name,
        catch_: Catch,
        /// A token the recovering parser could not start a statement
        /// with, and the message describing it. Only the tooling parse
        /// (`debug.parse`) produces it, and the compiler skips it.
        recovered: []const u8,
    };
};

pub const GroupInit = union(enum) {
    ctor: []GroupField,
    copy: Name,
};

pub const GroupField = struct {
    name: AttName,
    value: union(enum) { expr: *Expr, group: []GroupField },
};

pub const IfClause = struct {
    cond: Cond,
    body: *Block,
    line: u32,
};

/// The condition of `if`, `elseif`, or `while`: a plain expression or an
/// assignment condition that declares locals.
pub const Cond = union(enum) {
    expr: *Expr,
    assign: struct { names: []AttName, values: []*Expr },
    from: struct { names: []AttName, source: *Expr },
    group: struct { names: []AttName, inits: []GroupInit },
};

// ---------------------------------------------------------------------
// Queries

pub const Query = struct {
    sources: []QSource,
    where: ?*QExpr = null,
    select: ?[]QItem = null,
    distinct: bool = false,
    group_by: ?[]*QExpr = null,
    having: ?*QExpr = null,
    order_by: ?[]QOrder = null,
    limit: ?*QExpr = null,
    offset: ?*QExpr = null,
    span: Span,
};

pub const QSource = struct {
    expr: *Expr,
    alias: Name,
};

pub const QItem = struct {
    expr: *QExpr,
    alias: ?Name,
};

pub const QOrder = struct {
    expr: *QExpr,
    desc: bool,
};

pub const Aggregate = enum { count, sum, avg, min, max };

pub const QExpr = struct {
    span: Span,
    line: u32,
    kind: union(enum) {
        literal: *Expr,
        /// A name chain `a.b.c`. Resolved later into a row reference, a
        /// column reference, an alias reference, or a bound parameter.
        chain: []Name,
        paren: *QExpr,
        unop: struct { op: UnOp, operand: *QExpr },
        binop: struct { op: BinOp, lhs: *QExpr, rhs: *QExpr },
        aggregate: struct { func: Aggregate, arg: ?*QExpr },
        /// Any other expression, evaluated per row by a host closure whose
        /// parameters are the row variables.
        host: *Expr,
    },
};

pub const Chunk = struct {
    block: *Block,
    source: []const u8,
    comments: []const @import("lexer.zig").Comment,
};
