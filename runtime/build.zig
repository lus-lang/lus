const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested: Features = .{
        .gc_stress = b.option(u32, "gc-stress", "Collect at every Nth allocation point to expose missing roots (0 disables)") orelse 0,
        .gc_verify = b.option(bool, "gc-verify", "Check the tri-color invariant and barrier coverage after every mark phase") orelse false,
        .net = b.option(bool, "net", "Include the network library (default: true, false on WebAssembly)"),
        .sqlite = b.option(bool, "sqlite", "Include SQLite (default: true)"),
        .workers = b.option(bool, "workers", "Include the worker library (default: true, false on WebAssembly)"),
        .archive = b.option(bool, "archive", "Include vector.archive compression (default: true)"),
        .jit = b.option(bool, "jit", "Include the baseline JIT on targets that have one (default: true)") orelse true,
    };
    const options = requested.resolve(b, target);
    const features = requested.forTarget(target);
    // ThreadSanitizer, for the parallel marker of the collector.
    const tsan = b.option(bool, "sanitize-thread", "Build the lus executable with ThreadSanitizer (default: false)") orelse false;

    const lus_mod = b.createModule(.{
        .root_source_file = b.path("src/lus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = if (tsan) true else null,
    });
    lus_mod.addOptions("build_options", options);
    if (features.archive) lus_mod.linkLibrary(compressionLibrary(b, target));
    if (features.sqlite) lus_mod.linkLibrary(sqliteLibrary(b, target));

    const exe = b.addExecutable(.{
        .name = "lus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lus", .module = lus_mod }},
            .sanitize_thread = if (tsan) true else null,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the lus interpreter").dependOn(&run.step);

    // `lus build` on tests/build, then the standalone program it made,
    // run from a directory without the sources.
    const bundle_step = b.step("test-bundle", "Build a standalone executable and run it");
    const make = b.addRunArtifact(exe);
    make.setCwd(b.path("../tests/build"));
    make.addArgs(&.{ "build", "-F", "mode=prod", "--include", "extra", "-o" });
    const app = make.addOutputFileArg("app");
    make.addArg("app.lus");
    const run_app = std.Build.Step.Run.create(b, "run bundled app");
    run_app.addFileArg(app);
    run_app.addArgs(&.{ "there", "-P", "all" });
    run_app.setCwd(b.path("../tests/embed"));
    run_app.expectStdOutEqual("hello there\nhello deep\nargs 3\nflag prod\nfs denied true\ndynamic 5\n");
    bundle_step.dependOn(&run_app.step);
    const run_fail = std.Build.Step.Run.create(b, "run bundled app that fails");
    run_fail.addFileArg(app);
    run_fail.addArg("boom");
    run_fail.setCwd(b.path("../tests/embed"));
    run_fail.expectExitCode(1);
    run_fail.expectStdErrMatch("app.lus:22: boom from the bundle");
    bundle_step.dependOn(&run_fail.step);

    // `lus check` and `lus doc` on the fixtures in tests/check and
    // tests/doc. Each fixture's output must match its expected file.
    const check_step = b.step("test-check", "Run lus check on the fixtures in tests/check");
    fixtureSuite(b, exe, check_step, "check", &.{".expected"});
    const doc_step = b.step("test-doc", "Run lus doc on the fixtures in tests/doc");
    fixtureSuite(b, exe, doc_step, "doc", &.{ ".md", ".json" });

    // `lus debug` driven by the scripted DAP client in tests/debug.
    const debug_step = b.step("test-debug", "Drive lus debug with the scripted DAP client in ../tests/debug");
    const debug_run = b.addSystemCommand(&.{"node"});
    debug_run.setName("lus debug (DAP client)");
    debug_run.addFileArg(b.path("../tests/debug/run.mjs"));
    debug_run.addArtifactArg(exe);
    debug_run.addFileInput(b.path("../tests/debug/fixture.lus"));
    debug_run.addFileInput(b.path("../tests/debug/coroutine.lus"));
    debug_step.dependOn(&debug_run.step);

    const unit = b.addTest(.{ .root_module = lus_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // The C embedding library: `liblus.a`, the shared `liblus`, and the
    // header `lus.h`. Each library carries the vendored C code, so a host
    // links one file.
    const static_lib = embedLibrary(b, target, optimize, .static, options, features);
    const shared_lib = embedLibrary(b, target, optimize, .dynamic, options, features);
    const lib_step = b.step("lib", "Build the C embedding libraries and install lus.h");
    const header = b.addInstallHeaderFile(b.path("include/lus.h"), "lus.h");
    // On Windows the static library and the import library of the DLL
    // would share the name lus.lib, so the static one is lus_static.lib.
    // The DLL keeps its debug info out of bin, where lus.pdb belongs to
    // the interpreter.
    const windows = target.result.os.tag == .windows;
    lib_step.dependOn(&b.addInstallArtifact(static_lib, .{
        .dest_sub_path = if (windows) "lus_static.lib" else null,
    }).step);
    lib_step.dependOn(&b.addInstallArtifact(shared_lib, .{
        .pdb_dir = if (windows) .disabled else .default,
    }).step);
    lib_step.dependOn(&header.step);

    // Small C hosts that exercise every part of the embedding interface.
    const embed_step = b.step("test-embed", "Build and run the C embedding tests");
    const embed_tests = [_][]const u8{ "state", "values", "tables", "functions", "userdata", "errors", "pledge", "shared" };
    for (embed_tests) |name| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        mod.addIncludePath(b.path("include"));
        mod.addCSourceFile(.{
            .file = b.path(b.fmt("../tests/embed/{s}.c", .{name})),
            .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
        });
        mod.linkLibrary(if (std.mem.eql(u8, name, "shared")) shared_lib else static_lib);
        const exe_t = b.addExecutable(.{ .name = b.fmt("embed-{s}", .{name}), .root_module = mod });
        const run_t = b.addRunArtifact(exe_t);
        // The shared library is found through a path relative to the build
        // root, so that test keeps the default working directory.
        if (!std.mem.eql(u8, name, "shared")) run_t.setCwd(b.path("../tests/embed"));
        run_t.expectExitCode(0);
        embed_step.dependOn(&run_t.step);
    }

    // `zig build wasm` makes zig-out/wasm/lus.wasm. It keeps safety checks
    // unless -Dwasm-optimize names another mode, because the playground
    // runs untrusted code and a failed check traps instead of corrupting
    // memory. The safe build is about 15 percent larger than a small one.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimization mode of the WebAssembly build: debug, safe, fast, or small (default: safe)") orelse std.builtin.OptimizeMode.ReleaseSafe;
    const wasm = wasmModule(b, requested, wasm_optimize);
    const wasm_step = b.step("wasm", "Build lus.wasm for wasm32-wasi");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
}

/// Adds one run of `lus <command>` per fixture in `../tests/<command>`.
/// For a fixture `NAME.lus`, every expected file `NAME<ext>` that exists
/// adds a run whose standard output must equal it. The `.json` expected
/// file runs with `--format json`. A first line `-- args: ...` in the
/// fixture adds arguments before the file name. A run that prints
/// nothing must exit with status 0, and any other run with status 1 for
/// `check` and 0 for `doc`.
fn fixtureSuite(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step, command: []const u8, exts: []const []const u8) void {
    const io = b.graph.io;
    const rel = b.fmt("../tests/{s}", .{command});
    // The configure step reads the fixtures, so it reruns when they
    // change.
    b.dependOnDirectoryContents(b.path(rel));
    const root = b.root.join(b.allocator, rel) catch @panic("OOM");
    var dir = root.root_dir.handle.openDir(io, root.sub_path, .{ .iterate = true }) catch |e| {
        std.debug.panic("cannot open {s}: {s}", .{ rel, @errorName(e) });
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lus")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (names.items) |name| {
        const stem = name[0 .. name.len - 4];
        b.dependOnFileContents(b.path(b.fmt("{s}/{s}", .{ rel, name })));
        const src = dir.readFileAlloc(io, name, b.allocator, .unlimited) catch @panic("cannot read fixture");
        const first = src[0 .. std.mem.indexOfScalar(u8, src, '\n') orelse src.len];
        for (exts) |ext| {
            const expected_name = b.fmt("{s}{s}", .{ stem, ext });
            const expected = dir.readFileAlloc(io, expected_name, b.allocator, .unlimited) catch continue;
            b.dependOnFileContents(b.path(b.fmt("{s}/{s}", .{ rel, expected_name })));
            const run = b.addRunArtifact(exe);
            run.setName(b.fmt("lus {s} {s} ({s})", .{ command, name, ext }));
            run.setCwd(b.path(rel));
            run.addArg(command);
            if (std.mem.eql(u8, ext, ".json")) run.addArgs(&.{ "--format", "json" });
            const prefix = "-- args: ";
            if (std.mem.startsWith(u8, first, prefix)) {
                var words = std.mem.tokenizeScalar(u8, first[prefix.len..], ' ');
                while (words.next()) |w| run.addArg(w);
            }
            run.addArg(name);
            run.addFileInput(b.path(b.fmt("{s}/{s}", .{ rel, name })));
            run.expectStdOutEqual(expected);
            const failing = std.mem.eql(u8, command, "check") and expected.len > 0;
            run.expectExitCode(if (failing) 1 else 0);
            step.dependOn(&run.step);
        }
    }
}

/// The embedding library rooted at `src/capi.zig`. The vendored C sources
/// are compiled into it, so the archive is self-contained.
fn embedLibrary(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, linkage: std.builtin.LinkMode, options: *std.Build.Step.Options, features: Features.Resolved) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    if (vendorModule(b, target, .{ .archive = features.archive, .sqlite = features.sqlite })) |v| mod.addImport("vendor", v);
    mod.addOptions("build_options", options);
    return b.addLibrary(.{ .name = "lus", .linkage = linkage, .root_module = mod });
}

/// The libraries a build includes. A null field takes the default for the
/// target: everything on native targets, and on WebAssembly everything
/// except the network and worker libraries, which need sockets and
/// threads that WASI does not provide.
const Features = struct {
    gc_stress: u32 = 0,
    gc_verify: bool = false,
    net: ?bool = null,
    sqlite: ?bool = null,
    workers: ?bool = null,
    archive: ?bool = null,
    jit: bool = true,

    const Resolved = struct { net: bool, sqlite: bool, workers: bool, archive: bool };

    fn forTarget(f: Features, target: std.Build.ResolvedTarget) Resolved {
        const wasm = target.result.cpu.arch.isWasm();
        return .{
            .net = f.net orelse !wasm,
            .sqlite = f.sqlite orelse true,
            .workers = f.workers orelse !wasm,
            .archive = f.archive orelse true,
        };
    }

    fn resolve(f: Features, b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Options {
        const r = f.forTarget(target);
        const options = b.addOptions();
        options.addOption(u32, "gc_stress", f.gc_stress);
        options.addOption(bool, "gc_verify", f.gc_verify);
        options.addOption(bool, "net", r.net);
        options.addOption(bool, "sqlite", r.sqlite);
        options.addOption(bool, "workers", r.workers);
        options.addOption(bool, "archive", r.archive);
        options.addOption(bool, "jit", f.jit);
        return options;
    }
};

/// The WebAssembly build: `lus.wasm`, a WASI reactor that exports the C
/// embedding interface of `include/lus.h` and the helpers of
/// `src/wasm.zig` for the JavaScript host in `packages/wasm`. It has no `main`.
/// The host calls `_initialize` once and then drives states through the
/// exported functions.
fn wasmModule(b: *std.Build, requested: Features, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const features = requested.forTarget(target);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Debug information would triple the download, so only debug
        // builds keep it.
        .strip = optimize != .debug,
    });
    if (vendorModule(b, target, .{ .archive = features.archive, .sqlite = features.sqlite })) |v| mod.addImport("vendor", v);
    mod.addOptions("build_options", requested.resolve(b, target));
    mod.export_symbol_names = wasmExports(b);
    const exe = b.addExecutable(.{ .name = "lus", .root_module = mod });
    exe.entry = .disabled;
    exe.wasi_exec_model = .reactor;
    // The JIT installs compiled functions in the function table, so the
    // host needs the table and must be able to grow it.
    exe.export_table = true;
    exe.growable_table = true;
    // The compiler passes recurse once per level of the expression tree,
    // which the parser bounds, so the shadow stack gets the same 8 MB the
    // native main thread starts with.
    exe.stack_size = 8 << 20;
    return exe;
}

/// Builds the vendored Brotli and Zstandard C sources used by
/// `vector.archive`. The upstream libraries are mature and fuzzed, so they
/// always build optimized and without the undefined behavior sanitizer,
/// whatever mode the runtime itself uses.
fn compressionLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lus_compress",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .pic = true,
        }),
    });
    addCompressionSources(b, lib.root_module);
    return lib;
}

fn addCompressionSources(b: *std.Build, mod: *std.Build.Module) void {
    const flags: []const []const u8 = &.{"-fno-sanitize=undefined"};

    const brotli = b.dependency("brotli", .{});
    mod.addIncludePath(brotli.path("c/include"));
    mod.addCSourceFiles(.{
        .root = brotli.path("c"),
        .files = &.{
            "common/constants.c",         "common/context.c",
            "common/dictionary.c",        "common/platform.c",
            "common/shared_dictionary.c", "common/transform.c",
            "dec/bit_reader.c",           "dec/decode.c",
            "dec/huffman.c",              "dec/state.c",
            "enc/backward_references.c",  "enc/backward_references_hq.c",
            "enc/bit_cost.c",             "enc/block_splitter.c",
            "enc/brotli_bit_stream.c",    "enc/cluster.c",
            "enc/command.c",              "enc/compound_dictionary.c",
            "enc/compress_fragment.c",    "enc/compress_fragment_two_pass.c",
            "enc/dictionary_hash.c",      "enc/encode.c",
            "enc/encoder_dict.c",         "enc/entropy_encode.c",
            "enc/fast_log.c",             "enc/histogram.c",
            "enc/literal_cost.c",         "enc/memory.c",
            "enc/metablock.c",            "enc/static_dict.c",
            "enc/utf8_util.c",
        },
        .flags = flags,
    });

    // Zstandard builds without its x86 assembly decoder loop, so one
    // source list serves every target.
    const zstd = b.dependency("zstd", .{});
    mod.addCMacro("ZSTD_DISABLE_ASM", "1");
    mod.addCMacro("ZSTD_MULTITHREAD_SUPPORT_DEFAULT", "0");
    mod.addIncludePath(zstd.path("lib"));
    mod.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "common/debug.c",                      "common/entropy_common.c",
            "common/error_private.c",              "common/fse_decompress.c",
            "common/pool.c",                       "common/threading.c",
            "common/xxhash.c",                     "common/zstd_common.c",
            "compress/fse_compress.c",             "compress/hist.c",
            "compress/huf_compress.c",             "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",   "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",                "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",                 "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",            "compress/zstdmt_compress.c",
            "decompress/huf_decompress.c",         "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",        "decompress/zstd_decompress_block.c",
        },
        .flags = flags,
    });
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

/// The symbols `lus.wasm` exports: every function declared in
/// `include/lus.h` and every `export fn` of `src/wasm.zig`. The list
/// comes from the header itself, so the C and WebAssembly interfaces
/// cannot drift apart. Inline helpers in the header are skipped, since a
/// JavaScript host cannot call them anyway.
fn wasmExports(b: *std.Build) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var helpers = std.mem.splitSequence(u8, @embedFile("src/wasm.zig"), "export fn ");
    _ = helpers.next();
    while (helpers.next()) |rest| {
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        names.append(b.allocator, rest[0..paren]) catch @panic("OOM");
    }
    var lines = std.mem.splitScalar(u8, @embedFile("include/lus.h"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or !std.ascii.isAlphabetic(line[0])) continue;
        if (std.mem.startsWith(u8, line, "typedef") or std.mem.startsWith(u8, line, "static") or std.mem.startsWith(u8, line, "extern")) continue;
        const paren = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        var start = paren;
        while (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) start -= 1;
        const name = line[start..paren];
        if (std.mem.startsWith(u8, name, "lus_")) names.append(b.allocator, name) catch @panic("OOM");
    }
    return names.items;
}

/// Extra flags for SQLite on WASI. SQLite detects WASI by itself and then
/// uses dot-file locking. WASI has no shared memory and no descriptor
/// duplication, so the write-ahead log and memory mapping are compiled
/// out, and wasi-libc emulates `mmap`, `getpid`, and signals for the rest
/// of the unix VFS. The descriptor-binding bridge of the pledge VFS is
/// only reached with a write-ahead log, so its `F_DUPFD_CLOEXEC` gets an
/// inert value.
const sqlite_wasi_flags = [_][]const u8{
    "-DSQLITE_OMIT_WAL",
    "-DSQLITE_MAX_MMAP_SIZE=0",
    "-DSQLITE_OMIT_POPEN",
    "-D_WASI_EMULATED_MMAN",
    "-D_WASI_EMULATED_GETPID",
    "-D_WASI_EMULATED_SIGNAL",
    "-DF_DUPFD_CLOEXEC=-1",
};

fn addSqliteSource(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .wasi) {
        mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &(sqlite_flags ++ sqlite_wasi_flags) });
        mod.linkSystemLibrary("wasi-emulated-mman", .{});
        mod.linkSystemLibrary("wasi-emulated-getpid", .{});
        mod.linkSystemLibrary("wasi-emulated-signal", .{});
    } else {
        mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &sqlite_flags });
    }
}

/// SQLite always builds optimized, whatever the mode of the runtime, so
/// debug builds of the interpreter stay usable.
fn sqliteLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .pic = true,
    });
    addSqliteSource(b, mod, target);
    return b.addLibrary(.{ .name = "sqlite3", .linkage = .static, .root_module = mod });
}

/// Every vendored C source in one optimized module. The embedding library
/// imports it, so the C objects land inside `liblus.a` itself. Returns
/// null when the build includes no vendored library.
fn vendorModule(b: *std.Build, target: std.Build.ResolvedTarget, include: struct { archive: bool, sqlite: bool }) ?*std.Build.Module {
    if (!include.archive and !include.sqlite) return null;
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .pic = true,
    });
    if (include.archive) addCompressionSources(b, mod);
    if (include.sqlite) addSqliteSource(b, mod, target);
    return mod;
}
