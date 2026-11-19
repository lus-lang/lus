//! Query objects created by the `@source where ...` syntax. The full
//! implementation lands with the language extensions in M3.

const std = @import("std");
const gc = @import("gc.zig");
const state = @import("state.zig");

pub const Query = struct {
    hdr: gc.Header,

    pub fn allocSizeOf(h: *gc.Header) usize {
        _ = h;
        return @sizeOf(Query);
    }
    pub fn freeExtra(g: *state.Global, h: *gc.Header) void {
        _ = g;
        _ = h;
    }
    pub fn traverse(m: *gc.MarkerApi, h: *gc.Header) void {
        _ = m;
        _ = h;
    }
};

const value = @import("value.zig");

pub fn build(l: *state.Thread, plan: value.Value, sources: u32) state.Error!value.Value {
    _ = plan;
    _ = sources;
    return l.raiseMsg("queries are not supported yet");
}
