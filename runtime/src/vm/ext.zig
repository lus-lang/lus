//! Runtime support for Lus extension opcodes: slices, enums, and queries.

const std = @import("std");
const value = @import("value.zig");
const state = @import("state.zig");
const Value = value.Value;
const Thread = state.Thread;
const Error = state.Error;

pub fn slice(l: *Thread, obj: Value, from: Value, to: Value) Error!Value {
    _ = obj;
    _ = from;
    _ = to;
    return l.raiseMsg("slices are not implemented yet");
}

pub fn newEnum(l: *Thread, desc: Value) Error!Value {
    _ = desc;
    return l.raiseMsg("enums are not implemented yet");
}

pub fn newQuery(l: *Thread, plan: Value, sources: u32) Error!Value {
    _ = plan;
    _ = sources;
    return l.raiseMsg("queries are not implemented yet");
}
