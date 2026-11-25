//! Applies the fixes of diagnostics to a source, for `lus check --fix`
//! and any pass that attaches fixes to its diagnostics.
//!
//! The edits of one diagnostic apply together or not at all. Diagnostics
//! are taken in source order of their first edit. A diagnostic whose edits
//! overlap each other, or overlap an edit already taken, is dropped, so
//! one run never applies two rewrites of the same bytes. The taken edits
//! then apply from the end of the source backwards, which keeps the
//! offsets of the edits before each one valid.

const std = @import("std");
const lint = @import("lint.zig");
const Allocator = std.mem.Allocator;

pub const Applied = struct {
    text: []const u8,
    /// How many diagnostics had their fix applied.
    count: usize,
};

fn overlaps(a: lint.Edit, b: lint.Edit) bool {
    // Two insertions at one offset overlap, so their order never matters.
    if (a.span.start == b.span.start) return true;
    return a.span.start < b.span.end and b.span.start < a.span.end;
}

fn firstStart(d: lint.Diagnostic) u32 {
    var m: u32 = std.math.maxInt(u32);
    for (d.fix) |e| m = @min(m, e.span.start);
    return m;
}

/// Returns the source with the fixes of `diags` applied, or null when no
/// fix applies.
pub fn apply(arena: Allocator, src: []const u8, diags: []const lint.Diagnostic) Allocator.Error!?Applied {
    var order: std.ArrayList(lint.Diagnostic) = .empty;
    for (diags) |d| if (d.fix.len > 0) try order.append(arena, d);
    if (order.items.len == 0) return null;
    std.mem.sort(lint.Diagnostic, order.items, {}, struct {
        fn lt(_: void, a: lint.Diagnostic, b: lint.Diagnostic) bool {
            return firstStart(a) < firstStart(b);
        }
    }.lt);

    var taken: std.ArrayList(lint.Edit) = .empty;
    var count: usize = 0;
    for (order.items) |d| {
        const ok = blk: {
            for (d.fix, 0..) |e, i| {
                if (e.span.end < e.span.start or e.span.end > src.len) break :blk false;
                for (d.fix[i + 1 ..]) |f| if (overlaps(e, f)) break :blk false;
                for (taken.items) |t| if (overlaps(e, t)) break :blk false;
            }
            break :blk true;
        };
        if (!ok) continue;
        try taken.appendSlice(arena, d.fix);
        count += 1;
    }
    if (count == 0) return null;

    std.mem.sort(lint.Edit, taken.items, {}, struct {
        fn gt(_: void, a: lint.Edit, b: lint.Edit) bool {
            return a.span.start > b.span.start;
        }
    }.gt);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, src);
    for (taken.items) |e| try text.replaceRange(arena, e.span.start, e.span.end - e.span.start, e.text);
    return .{ .text = text.items, .count = count };
}

const testing = std.testing;

fn diag(edits: []const lint.Edit) lint.Diagnostic {
    return .{ .span = .{ .start = 0, .end = 0 }, .severity = .hint, .code = "x", .message = "", .fix = edits };
}

test "edits apply together and overlapping fixes are dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "local a = b and b.c";
    const ds = [_]lint.Diagnostic{
        diag(&.{.{ .span = .{ .start = 6, .end = 6 }, .text = "_" }}),
        diag(&.{.{ .span = .{ .start = 10, .end = 19 }, .text = "b?.c" }}),
        // Starts after the second fix and overlaps it, so it is dropped
        // whole, its first edit included.
        diag(&.{ .{ .span = .{ .start = 12, .end = 13 }, .text = "y" }, .{ .span = .{ .start = 19, .end = 19 }, .text = "!" } }),
    };
    const r = (try apply(a, src, &ds)).?;
    try testing.expectEqualStrings("local _a = b?.c", r.text);
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expect(try apply(a, src, &.{}) == null);
}
