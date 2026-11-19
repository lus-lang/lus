const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lus_mod = b.createModule(.{
        .root_source_file = b.path("src/lus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lus_mod.linkLibrary(sqliteLibrary(b, target));

    const exe = b.addExecutable(.{
        .name = "lus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lus", .module = lus_mod }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the lus interpreter").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = lus_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

/// Flags for the embedded SQLite amalgamation (vendor/sqlite). Each
/// connection stays confined to one interpreter state, so serialized
/// threading (2) suffices. TEMP_STORE=3 keeps statement journals and temp
/// b-trees in memory, so SQLite never writes outside the paths the pledge
/// checks cover. Extension loading is compiled out.
const sqlite_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=2",
    "-DSQLITE_TEMP_STORE=3",
    "-DSQLITE_DQS=0",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_OMIT_DECLTYPE",
    "-DSQLITE_OMIT_AUTOINIT",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_MAX_EXPR_DEPTH=0",
    "-DSQLITE_ENABLE_MATH_FUNCTIONS",
    "-fno-sanitize=undefined",
};

/// SQLite always builds optimized, whatever the mode of the runtime, so
/// debug builds of the interpreter stay usable.
fn sqliteLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &sqlite_flags });
    return b.addLibrary(.{ .name = "sqlite3", .linkage = .static, .root_module = mod });
}
