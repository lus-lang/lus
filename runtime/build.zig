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
        .op_profile = b.option(bool, "op-profile", "Count the opcode sequences the interpreter runs and print them at exit (default: false)") orelse false,
        .version = b.option([]const u8, "version", "The version the binary reports, such as 2.0.0-unstable.7 (default: the version in build.zig.zon)"),
        .fail_alloc = b.option(bool, "fail-alloc", "Fail the allocation that LUS_FAIL_ALLOC names, to test out of memory handling (default: false)") orelse false,
        .coverage = b.option(bool, "coverage", "Instrument every edge and write the edges a run reached to LUS_COVERAGE (default: false)") orelse false,
        .fail_io = b.option(bool, "fail-io", "Fail or shorten the file and socket operation that LUS_FAIL_IO names, to test I/O error handling (default: false)") orelse false,
        .compiler = b.option(bool, "compiler", "Include the parser and the compiler, which `load` of source text and the tools need (default: true)") orelse true,
        .link_object = b.option(bool, "link-object", "Export the registrations of builtins for the link object of `lus build --aot` (default: false)") orelse false,
        .jit_compile = b.option(bool, "jit-compile", "Compile native code, where the JIT is included, rather than only run the code an executable compiled ahead of time carries (default: true)") orelse true,
        .invariants = b.option(bool, "invariants", "Check internal invariants, as Debug builds and the unit tests always do (default: false)") orelse false,
    };
    const options = requested.resolve(b, target);
    const features = requested.forTarget(target);
    // ThreadSanitizer, for the parallel marker of the collector.
    const tsan = b.option(bool, "sanitize-thread", "Build the lus executable with ThreadSanitizer (default: false)") orelse false;
    vendor_sanitize = b.option(bool, "sanitize-c", "Build the vendored C libraries in safe mode with the undefined behavior sanitizer (default: false)") orelse false;

    const lus_mod = b.createModule(.{
        .root_source_file = b.path("src/lus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = if (tsan) true else null,
        .fuzz = if (requested.coverage) true else null,
        .sanitize_c = vendorSanitizeC(),
    });
    lus_mod.addOptions("build_options", options);
    lus_mod.addImport("agent_docs", agentDocsModule(b));
    linkSystemLibraries(lus_mod, target);
    if (features.archive) lus_mod.linkLibrary(compressionLibrary(b, target));
    if (features.net) lus_mod.linkLibrary(tlsLibrary(b, target));
    if (features.sqlite) lus_mod.linkLibrary(sqliteLibrary(b, target));

    const exe = b.addExecutable(.{
        .name = "lus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lus", .module = lus_mod }},
            .sanitize_thread = if (tsan) true else null,
            .fuzz = if (requested.coverage) true else null,
            // The vendored libraries call the sanitizer runtime, which the
            // executable links when one of its own modules asks for it.
            .sanitize_c = vendorSanitizeC(),
        }),
    });
    // The test runner links its own definition, so only the executable
    // takes this one.
    if (requested.coverage) exe.root_module.addCSourceFile(.{ .file = b.path("src/coverage_tls.c") });
    // A position-independent executable loads above 4 GB on 64-bit Linux,
    // as every executable does on macOS, so the training run of `lus
    // build --aot` tells its addresses apart from integers of the program.
    if (target.result.os.tag == .linux and target.result.ptrBitWidth() == 64) exe.pie = true;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the lus interpreter").dependOn(&run.step);

    // The runtime of executables compiled ahead of time
    // (`../spec/design/aot.md`): the interpreter, the libraries, and the
    // part of the JIT that runs native code, without the parser, the
    // compiler, the tools, or the compilers of the JIT. It runs the bundle
    // appended to it and nothing else.
    const rt_exe = blk: {
        var rt = requested;
        rt.compiler = false;
        // The JIT runs the code that the executable carries and compiles
        // nothing (`--aot-keep-jit` bundles on `lus` itself instead).
        rt.jit_compile = false;
        const rt_mod = b.createModule(.{
            .root_source_file = b.path("src/lus.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        rt_mod.addOptions("build_options", rt.resolve(b, target));
        rt_mod.addImport("agent_docs", agentDocsModule(b));
        linkSystemLibraries(rt_mod, target);
        if (features.archive) rt_mod.linkLibrary(compressionLibrary(b, target));
        if (features.net) rt_mod.linkLibrary(tlsLibrary(b, target));
        if (features.sqlite) rt_mod.linkLibrary(sqliteLibrary(b, target));
        const rt_exe = b.addExecutable(.{
            .name = "lus-runtime",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lus", .module = rt_mod }},
            }),
        });
        b.step("runtime", "Build lus-runtime, the base of executables compiled ahead of time").dependOn(&b.addInstallArtifact(rt_exe, .{}).step);

        // The input of the link object (`../spec/design/aot.md`, "The link
        // object"): the same runtime as one relocatable object with a
        // section for each function and each datum, which also exports
        // the registrations of builtins. The object of the whole `lus`
        // tests the linker on the conformance suite.
        const lo_obj = linkObjectInput(b, rt, target, optimize, "lus-runtime");
        const lo_full = linkObjectInput(b, requested, target, optimize, "lus");
        const lo_step = b.step("link-object", "Build the runtime as a relocatable object and its C libraries for the link object");
        lo_step.dependOn(&b.addInstallFile(lo_obj.getEmittedBin(), "lib/lus-runtime.o").step);
        lo_step.dependOn(&b.addInstallFile(lo_full.getEmittedBin(), "lib/lus.o").step);
        const lo_compress = if (features.archive) compressionLibrary(b, target) else null;
        const lo_sqlite = if (features.sqlite) sqliteLibrary(b, target) else null;
        const lo_tls = if (features.net) tlsLibrary(b, target) else null;
        if (lo_compress) |l| lo_step.dependOn(&b.addInstallArtifact(l, .{}).step);
        if (lo_tls) |l| lo_step.dependOn(&b.addInstallArtifact(l, .{}).step);
        if (lo_sqlite) |l| lo_step.dependOn(&b.addInstallArtifact(l, .{}).step);
        const os_tag = target.result.os.tag;
        if (os_tag == .linux or os_tag == .macos or os_tag == .ios) {
            const convert = b.addExecutable(.{ .name = "lus-convert", .root_module = b.createModule(.{
                .root_source_file = b.path("src/link/convert.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }) });
            // `lus-link` links a link object with every builtin, which
            // tests the linker on the whole `lus` and the conformance suite.
            lo_step.dependOn(&b.addInstallArtifact(b.addExecutable(.{ .name = "lus-link", .root_module = b.createModule(.{
                .root_source_file = b.path("src/link/main.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }) }), .{}).step);
            const macho = os_tag != .linux;
            // Zig compiles part of musl from its own sources into each
            // executable, so the link object takes that part as an object.
            // On macOS and iOS the C library is libSystem, which the
            // executable loads.
            const zigc = b.addObject(.{ .name = "zigc", .root_module = b.createModule(.{
                .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ std.fs.path.dirname(b.graph.zig_exe) orelse ".", "lib", "c.zig" }) },
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) });
            zigc.link_function_sections = true;
            zigc.link_data_sections = true;
            // The link line of an empty program names the startup object,
            // libc, and compiler_rt that Zig built for the target.
            const stub = b.addWriteFiles().add("stub.zig", "pub fn main() void {}\n");
            const line = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-lc", "--verbose-link", "-OReleaseFast", "-target", target.result.zigTriple(b.allocator) catch @panic("OOM") });
            line.addFileArg(stub);
            _ = line.addPrefixedOutputFileArg("-femit-bin=", "stub");
            const link_line = line.captureStdErr(.{});
            for ([_]struct { []const u8, *std.Build.Step.Compile }{ .{ "lus-runtime.lo", lo_obj }, .{ "lus.lo", lo_full } }) |e| {
                const conv = b.addRunArtifact(convert);
                conv.addArgs(&.{ "--arch", @tagName(target.result.cpu.arch), "--os", @tagName(os_tag) });
                if (macho) {
                    conv.addArgs(&.{ "--entry", "main" });
                } else {
                    conv.addArg("--link-line");
                    conv.addFileArg(link_line);
                }
                conv.addArg("-o");
                const out = conv.addOutputFileArg(e[0]);
                conv.addFileArg(e[1].getEmittedBin());
                if (!macho) conv.addFileArg(zigc.getEmittedBin());
                if (lo_compress) |l| conv.addArtifactArg(l);
                if (lo_sqlite) |l| conv.addArtifactArg(l);
                if (lo_tls) |l| conv.addArtifactArg(l);
                lo_step.dependOn(&b.addInstallFile(out, b.pathJoin(&.{ "lib", e[0] })).step);
            }
        }
        break :blk rt_exe;
    };

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

    // The same program on lus-runtime, which has no compiler, gives the
    // same output, and `load` of source text reports the missing compiler.
    const runtime_step = b.step("test-runtime", "Build a standalone executable on lus-runtime and run it");
    const make_rt = b.addRunArtifact(exe);
    make_rt.setCwd(b.path("../tests/build"));
    make_rt.addArgs(&.{ "build", "-F", "mode=prod", "--include", "extra", "--runtime" });
    make_rt.addArtifactArg(rt_exe);
    make_rt.addArg("-o");
    const app_rt = make_rt.addOutputFileArg("app");
    make_rt.addArg("app.lus");
    const run_app_rt = std.Build.Step.Run.create(b, "run bundled app on lus-runtime");
    run_app_rt.addFileArg(app_rt);
    run_app_rt.addArgs(&.{ "there", "-P", "all" });
    run_app_rt.setCwd(b.path("../tests/embed"));
    run_app_rt.expectStdOutEqual("hello there\nhello deep\nargs 3\nflag prod\nfs denied true\ndynamic 5\n");
    runtime_step.dependOn(&run_app_rt.step);
    const make_load = b.addRunArtifact(exe);
    make_load.setCwd(b.path("../tests/build"));
    make_load.addArgs(&.{ "build", "-P", "load", "--runtime" });
    make_load.addArtifactArg(rt_exe);
    make_load.addArg("-o");
    const app_load = make_load.addOutputFileArg("noload");
    make_load.addArg("noload.lus");
    const run_load = std.Build.Step.Run.create(b, "run load on lus-runtime");
    run_load.addFileArg(app_load);
    run_load.expectStdOutEqual("nil\tthe compiler is not part of this executable\n");
    runtime_step.dependOn(&run_load.step);
    // `lus build --aot` trains the program and appends its code to the
    // runtime, so its hot function is optimized from the start.
    const make_aot = b.addRunArtifact(exe);
    make_aot.setCwd(b.path("../tests/build"));
    make_aot.addArgs(&.{ "build", "--aot", "--runtime" });
    make_aot.addArtifactArg(rt_exe);
    make_aot.addArg("-o");
    const app_aot = make_aot.addOutputFileArg("aot");
    make_aot.addArg("aot.lus");
    _ = make_aot.captureStdOut(.{});
    const run_aot = std.Build.Step.Run.create(b, "run an executable compiled ahead of time");
    run_aot.addFileArg(app_aot);
    run_aot.expectStdOutEqual("fib optimized true\n6765\t5341338000\t500500\n500000.5\nobserved 10\n");
    runtime_step.dependOn(&run_aot.step);

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

    // `lus version` and `lus +REQUEST` against a release served on
    // loopback by ../tests/version (needs node).
    const version_step = b.step("test-version", "Run the version manager against a loopback release server");
    const version_run = b.addSystemCommand(&.{"node"});
    version_run.setName("lus version (loopback release)");
    version_run.addFileArg(b.path("../tests/version/version.test.mjs"));
    version_run.addArtifactArg(exe);
    version_run.addFileInput(b.path("../tests/lib/release.mjs"));
    version_step.dependOn(&version_run.step);

    // Remote requires against an atmosphere server and a generic server
    // served on loopback by ../tests/remote (needs node).
    const remote_step = b.step("test-remote", "Run remote requires against loopback module servers");
    const remote_run = b.addSystemCommand(&.{"node"});
    remote_run.setName("remote requires (loopback servers)");
    remote_run.addFileArg(b.path("../tests/remote/remote.test.mjs"));
    remote_run.addArtifactArg(exe);
    remote_run.addFileInput(b.path("../tests/lib/release.mjs"));
    remote_step.dependOn(&remote_run.step);

    const unit = b.addTest(.{
        .root_module = lus_mod,
        .filters = if (b.option([]const u8, "test-filter", "Run only the unit tests whose names contain this text")) |f| b.dupeStrings(&.{f}) else &.{},
        // The runner of the Zig library runs instrumented tests only under
        // the build server (`coverage_runner.zig`).
        .test_runner = if (requested.coverage) .{ .path = b.path("src/coverage_runner.zig"), .mode = .simple } else null,
    });
    b.step("unit-binary", "Install the unit tests as bin/lus-unit, which `mise run coverage:unit` runs").dependOn(&b.addInstallArtifact(unit, .{ .dest_sub_path = "lus-unit" }).step);
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
    const embed_tests = [_][]const u8{ "state", "values", "tables", "functions", "userdata", "errors", "pledge", "coroutines", "shared" };
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
            // `lus check` fails on an error or a warning. Hints alone
            // leave the exit status at zero.
            const failing = std.mem.eql(u8, command, "check") and
                (std.mem.indexOf(u8, expected, ": error: ") != null or std.mem.indexOf(u8, expected, ": warning: ") != null or
                    std.mem.indexOf(u8, expected, "\"severity\": \"error\"") != null or std.mem.indexOf(u8, expected, "\"severity\": \"warning\"") != null);
            run.expectExitCode(if (failing) 1 else 0);
            step.dependOn(&run.step);
        }
    }
}

/// The documentation that `lus help` and `lus agents init` read: every
/// entry of `../spec/stdlib` and every file of the agent skills in
/// `../.agents/skills`, embedded in a generated module whose `stdlib`
/// and `skills` lists pair a relative path with the file contents.
fn agentDocsModule(b: *std.Build) *std.Build.Module {
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    const w = struct {
        fn line(list: *std.ArrayList(u8), bb: *std.Build, comptime fmt: []const u8, args: anytype) void {
            list.appendSlice(bb.allocator, bb.fmt(fmt, args)) catch @panic("OOM");
        }
    };
    w.line(&src, b, "pub const File = struct {{ path: []const u8, data: []const u8 }};\n", .{});
    const groups = [_]struct { name: []const u8, rel: []const u8 }{
        .{ .name = "stdlib", .rel = "../spec/stdlib" },
        .{ .name = "skills", .rel = "../.agents/skills" },
    };
    for (groups) |g| {
        b.dependOnDirectoryContents(b.path(g.rel));
        w.line(&src, b, "pub const {s} = [_]File{{\n", .{g.name});
        const root = b.root.join(b.allocator, g.rel) catch @panic("OOM");
        var dir = root.root_dir.handle.openDir(b.graph.io, root.sub_path, .{ .iterate = true }) catch |e| {
            std.debug.panic("cannot open {s}: {s}", .{ g.rel, @errorName(e) });
        };
        defer dir.close(b.graph.io);
        var names: std.ArrayList([]const u8) = .empty;
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch null) |entry| {
            // The configure cache tracks the entries of one directory, not
            // of the directories below it, so every directory of the tree
            // is a dependency of its own. A file added to any of them then
            // reaches `lus help` on the next build.
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(b.path(b.fmt("{s}/{s}", .{ g.rel, entry.path })));
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;
            const rel = std.mem.replaceOwned(u8, b.allocator, entry.path, "\\", "/") catch @panic("OOM");
            names.append(b.allocator, rel) catch @panic("OOM");
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (names.items) |rel| {
            const dest = b.fmt("{s}/{s}", .{ g.name, rel });
            _ = wf.addCopyFile(b.path(b.fmt("{s}/{s}", .{ g.rel, rel })), dest);
            w.line(&src, b, "    .{{ .path = \"{s}\", .data = @embedFile(\"{s}\") }},\n", .{ rel, dest });
        }
        w.line(&src, b, "}};\n", .{});
    }
    const root = wf.add("agent_docs.zig", src.items);
    return b.createModule(.{ .root_source_file = root });
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
    if (vendorModule(b, target, .{ .archive = features.archive, .sqlite = features.sqlite, .net = features.net })) |v| mod.addImport("vendor", v);
    mod.addOptions("build_options", options);
    linkSystemLibraries(mod, target);
    return b.addLibrary(.{ .name = "lus", .linkage = linkage, .root_module = mod });
}

/// Links the system libraries the runtime calls beyond those every
/// program gets. On Windows the TLS client of the standard library reads
/// the certificate store through crypt32. An executable written in Zig
/// finds that library on its own, but a static library does not record
/// it, so declaring it here lets every artifact that links the runtime,
/// C hosts included, link it as well.
/// The runtime with the features `f` as one relocatable object for the
/// converter of the link object.
fn linkObjectInput(b: *std.Build, f: Features, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8) *std.Build.Step.Compile {
    var lo = f;
    lo.link_object = true;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/lus.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", lo.resolve(b, target));
    mod.addImport("agent_docs", agentDocsModule(b));
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "lus", .module = mod }},
        }),
    });
    obj.link_function_sections = true;
    obj.link_data_sections = true;
    obj.bundle_compiler_rt = true;
    return obj;
}

fn linkSystemLibraries(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("crypt32", .{});
        // The TLS layer reads random bytes through RtlGenRandom, and Mbed
        // TLS parses the addresses of certificates with inet_pton.
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("ws2_32", .{});
    }
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
    op_profile: bool = false,
    version: ?[]const u8 = null,
    fail_alloc: bool = false,
    fail_io: bool = false,
    coverage: bool = false,
    compiler: bool = true,
    jit_compile: bool = true,
    invariants: bool = false,
    link_object: bool = false,

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
        options.addOption(bool, "op_profile", f.op_profile);
        options.addOption(bool, "fail_alloc", f.fail_alloc);
        options.addOption(bool, "fail_io", f.fail_io);
        options.addOption(bool, "coverage", f.coverage);
        options.addOption(bool, "compiler", f.compiler);
        options.addOption(bool, "jit_compile", f.jit_compile);
        options.addOption(bool, "invariants", f.invariants);
        options.addOption(bool, "link_object", f.link_object);
        // The version that `lus -v` and the User-Agent of network.fetch
        // report. A release of an unstable channel sets it with `-Dversion`,
        // and every other build takes the version in build.zig.zon.
        options.addOption([]const u8, "version", f.version orelse @import("build.zig.zon").version);
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
/// Set by `-Dsanitize-c=true`: the vendored C libraries build in safe mode
/// with the undefined behavior sanitizer, which reports each finding with
/// its place, for the nightly job that runs SQLite, Zstandard, and Brotli
/// under it.
var vendor_sanitize = false;

fn vendorOptimize() std.builtin.OptimizeMode {
    return if (vendor_sanitize) .ReleaseSafe else .ReleaseFast;
}

fn vendorSanitizeC() ?std.zig.SanitizeC {
    return if (vendor_sanitize) .full else null;
}

fn compressionLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lus_compress",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = vendorOptimize(),
            .sanitize_c = vendorSanitizeC(),
            .link_libc = true,
            .pic = true,
        }),
    });
    addCompressionSources(b, lib.root_module);
    // A section for each function and datum lets the linker of `lus build
    // --aot` keep only the codecs a program reaches.
    lib.link_function_sections = true;
    lib.link_data_sections = true;
    return lib;
}

/// Builds the vendored Mbed TLS and the C part of the TLS layer
/// (`src/tls/shim.c`) for `network.tls`, HTTPS in `network.fetch`, and
/// `network.serve` with TLS. `src/tls/lus_mbedtls_config.h` trims the
/// default configuration of Mbed TLS. Every source compiles, and those of
/// the parts the configuration leaves out compile to nothing.
fn tlsLibrary(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lus_tls",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = vendorOptimize(),
            .sanitize_c = vendorSanitizeC(),
            .link_libc = true,
            .pic = true,
        }),
    });
    addTlsSources(b, lib.root_module);
    lib.link_function_sections = true;
    lib.link_data_sections = true;
    return lib;
}

fn addTlsSources(b: *std.Build, mod: *std.Build.Module) void {
    const flags: []const []const u8 = if (vendor_sanitize) &.{} else &.{"-fno-sanitize=undefined"};
    const mbedtls = b.dependency("mbedtls", .{});
    mod.addCMacro("MBEDTLS_USER_CONFIG_FILE", "\"lus_mbedtls_config.h\"");
    mod.addIncludePath(b.path("src/tls"));
    mod.addIncludePath(mbedtls.path("include"));
    mod.addIncludePath(mbedtls.path("library"));
    mod.addCSourceFiles(.{ .root = mbedtls.path("library"), .files = &mbedtls_sources, .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/tls/shim.c"), .flags = flags });
}

const mbedtls_sources = [_][]const u8{
    "aes.c",
    "aesce.c",
    "aesni.c",
    "aria.c",
    "asn1parse.c",
    "asn1write.c",
    "base64.c",
    "bignum.c",
    "bignum_core.c",
    "bignum_mod.c",
    "bignum_mod_raw.c",
    "block_cipher.c",
    "camellia.c",
    "ccm.c",
    "chacha20.c",
    "chachapoly.c",
    "cipher.c",
    "cipher_wrap.c",
    "cmac.c",
    "constant_time.c",
    "ctr_drbg.c",
    "debug.c",
    "des.c",
    "dhm.c",
    "ecdh.c",
    "ecdsa.c",
    "ecjpake.c",
    "ecp.c",
    "ecp_curves.c",
    "ecp_curves_new.c",
    "entropy.c",
    "entropy_poll.c",
    "error.c",
    "gcm.c",
    "hkdf.c",
    "hmac_drbg.c",
    "lmots.c",
    "lms.c",
    "md.c",
    "md5.c",
    "memory_buffer_alloc.c",
    "mps_reader.c",
    "mps_trace.c",
    "net_sockets.c",
    "nist_kw.c",
    "oid.c",
    "padlock.c",
    "pem.c",
    "pk.c",
    "pk_ecc.c",
    "pk_wrap.c",
    "pkcs12.c",
    "pkcs5.c",
    "pkcs7.c",
    "pkparse.c",
    "pkwrite.c",
    "platform.c",
    "platform_util.c",
    "poly1305.c",
    "psa_crypto.c",
    "psa_crypto_aead.c",
    "psa_crypto_cipher.c",
    "psa_crypto_client.c",
    "psa_crypto_driver_wrappers_no_static.c",
    "psa_crypto_ecp.c",
    "psa_crypto_ffdh.c",
    "psa_crypto_hash.c",
    "psa_crypto_mac.c",
    "psa_crypto_pake.c",
    "psa_crypto_random.c",
    "psa_crypto_rsa.c",
    "psa_crypto_se.c",
    "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",
    "psa_its_file.c",
    "psa_util.c",
    "ripemd160.c",
    "rsa.c",
    "rsa_alt_helpers.c",
    "sha1.c",
    "sha256.c",
    "sha3.c",
    "sha512.c",
    "ssl_cache.c",
    "ssl_ciphersuites.c",
    "ssl_client.c",
    "ssl_cookie.c",
    "ssl_debug_helpers_generated.c",
    "ssl_msg.c",
    "ssl_ticket.c",
    "ssl_tls.c",
    "ssl_tls12_client.c",
    "ssl_tls12_server.c",
    "ssl_tls13_client.c",
    "ssl_tls13_generic.c",
    "ssl_tls13_keys.c",
    "ssl_tls13_server.c",
    "threading.c",
    "timing.c",
    "version.c",
    "version_features.c",
    "x509.c",
    "x509_create.c",
    "x509_crl.c",
    "x509_crt.c",
    "x509_csr.c",
    "x509write.c",
    "x509write_crt.c",
    "x509write_csr.c",
};

fn addCompressionSources(b: *std.Build, mod: *std.Build.Module) void {
    const flags: []const []const u8 = if (vendor_sanitize) &.{} else &.{"-fno-sanitize=undefined"};

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
        .optimize = vendorOptimize(),
        .sanitize_c = vendorSanitizeC(),
        .link_libc = true,
        .pic = true,
    });
    addSqliteSource(b, mod, target);
    const lib = b.addLibrary(.{ .name = "sqlite3", .linkage = .static, .root_module = mod });
    lib.link_function_sections = true;
    lib.link_data_sections = true;
    return lib;
}

/// Every vendored C source in one optimized module. The embedding library
/// imports it, so the C objects land inside `liblus.a` itself. Returns
/// null when the build includes no vendored library.
fn vendorModule(b: *std.Build, target: std.Build.ResolvedTarget, include: struct { archive: bool, sqlite: bool, net: bool = false }) ?*std.Build.Module {
    if (!include.archive and !include.sqlite and !include.net) return null;
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .pic = true,
    });
    if (include.archive) addCompressionSources(b, mod);
    if (include.sqlite) addSqliteSource(b, mod, target);
    if (include.net) addTlsSources(b, mod);
    return mod;
}
