//! `lus build`: bundles a script and the modules it requires into a
//! standalone executable that runs without the source files.
//!
//! Usage: lus build [options] SCRIPT
//!
//!   -o FILE                the output path (default: the script name
//!                          without its extension)
//!   -P perm, --pledge perm grant a permission every time the program runs
//!   -F name[=value]        define a compile-time flag (also --flag)
//!   --include path[:alias] bundle a module file, or every module below a
//!                          directory, even when no literal `require`
//!                          names it
//!
//! The command compiles the script, finds every `require` call whose
//! argument is a string literal (`modtree.scan`), resolves those names through the default
//! module path (or `LUS_PATH`), and compiles the modules it finds,
//! recursively. Names that resolve to no file, such as standard library
//! modules, are left to the usual searchers at run time.
//! A directory named with `--include` contributes candidates: the bundle
//! keeps only those that a literal require reaches from the script or
//! from a file named with `--include`, unless some chunk loads modules
//! dynamically (`spec/design/modules.md`, section 2).
//!
//! The executable is a copy of the running `lus` with the compiled chunks
//! appended (see `bundle.zig`). It grants nothing implicitly: the program
//! runs with the permissions it pledges, plus those given with `-P` here,
//! exactly as `lus -P ... SCRIPT` would. Every command line argument goes
//! to the script.

const std = @import("std");
const builtin = @import("builtin");
const lus = @import("../lus.zig");
const bundle = @import("../bundle.zig");
const api = lus.api;
const codegen = lus.compile.codegen;
const dump = @import("../compile/dump.zig");
const libproof = @import("libproof.zig");
const lobj = @import("../link/lobj.zig");
const linker = @import("../link/link.zig");
const macho = @import("../link/macho.zig");
const reloc = @import("../jit/reloc.zig");
const aot = @import("../jit/aot.zig");
const jit = @import("../jit/jit.zig");
const package = lus.lib.package;
const modtree = lus.modtree;
const remote = lus.remote;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: lus build [options] SCRIPT
    \\
    \\Options:
    \\  -o FILE                 write the executable to FILE
    \\  -P perm                 grant a permission at every run (also --pledge)
    \\  -F name[=value]         define a compile-time flag (also --flag)
    \\  --include path[:alias]  bundle a module file or directory
    \\  --runtime FILE          start the executable from FILE, such as lus-runtime
    \\  --aot                   compile the program ahead of time from a training run
    \\  --train ARGS            the arguments of the training run, separated by spaces
    \\  --aot-keep-jit          keep the JIT, so code the training never reached compiles
    \\  --aot-static            compile ahead of time for a target without executable memory
    \\  --link-object FILE      link the executable from FILE, keeping only what the program reaches
    \\  --link-all              link every builtin of the link object
    \\  --link-map FILE         write the size of each linked atom and what reached it
    \\
;

const Options = struct {
    output: ?[]const u8 = null,
    script: ?[]const u8 = null,
    /// The executable that the bundle is appended to, in place of the
    /// running `lus`.
    runtime: ?[]const u8 = null,
    aot: bool = false,
    keep_jit: bool = false,
    /// Compiles ahead of time in the static form, for a target without
    /// executable memory.
    static: bool = false,
    train: ?[]const u8 = null,
    /// The link object to link the executable from, in place of a
    /// prebuilt runtime (`spec/design/aot.md`, "The linker").
    link_object: ?[]const u8 = null,
    link_all: bool = false,
    /// Where the linker writes the size of each kept atom and what kept it.
    link_map: ?[]const u8 = null,
    pledges: std.ArrayList([]const u8) = .empty,
    flags: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,

    fn deinit(o: *Options, gpa: Allocator) void {
        o.pledges.deinit(gpa);
        o.flags.deinit(gpa);
        o.includes.deinit(gpa);
    }
};

/// Parses the options. Returns null after printing a usage error.
fn parseOptions(gpa: Allocator, args: []const []const u8) !?Options {
    var o: Options = .{};
    errdefer o.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--aot")) {
            o.aot = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--link-all")) {
            o.link_all = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--aot-static")) {
            o.aot = true;
            o.static = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--aot-keep-jit")) {
            o.aot = true;
            o.keep_jit = true;
            continue;
        }
        const Kind = enum { output, pledge, flag, include, runtime, train, link_object, link_map };
        const kind: ?Kind = if (std.mem.eql(u8, a, "-o"))
            .output
        else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--pledge"))
            .pledge
        else if (std.mem.eql(u8, a, "-F") or std.mem.eql(u8, a, "--flag"))
            .flag
        else if (std.mem.eql(u8, a, "--include"))
            .include
        else if (std.mem.eql(u8, a, "--runtime"))
            .runtime
        else if (std.mem.eql(u8, a, "--train"))
            .train
        else if (std.mem.eql(u8, a, "--link-object"))
            .link_object
        else if (std.mem.eql(u8, a, "--link-map"))
            .link_map
        else
            null;
        if (kind) |k| {
            i += 1;
            if (i >= args.len) {
                std.debug.print("lus build: '{s}' needs an argument\n{s}", .{ a, usage });
                return null;
            }
            const v = args[i];
            switch (k) {
                .output => o.output = v,
                .pledge => try o.pledges.append(gpa, v),
                .flag => try o.flags.append(gpa, v),
                .include => try o.includes.append(gpa, v),
                .runtime => o.runtime = v,
                .train => o.train = v,
                .link_object => o.link_object = v,
                .link_map => o.link_map = v,
            }
        } else if (std.mem.startsWith(u8, a, "-P") and a.len > 2) {
            try o.pledges.append(gpa, a[2..]);
        } else if (std.mem.startsWith(u8, a, "-F") and a.len > 2) {
            try o.flags.append(gpa, a[2..]);
        } else if (std.mem.startsWith(u8, a, "--pledge=")) {
            try o.pledges.append(gpa, a["--pledge=".len..]);
        } else if (std.mem.startsWith(u8, a, "--flag=")) {
            try o.flags.append(gpa, a["--flag=".len..]);
        } else if (a.len > 1 and a[0] == '-') {
            std.debug.print("lus build: unknown option '{s}'\n{s}", .{ a, usage });
            return null;
        } else if (o.script == null) {
            o.script = a;
        } else {
            std.debug.print("lus build: more than one script given\n{s}", .{usage});
            return null;
        }
    }
    if (o.script == null) {
        std.debug.print("{s}", .{usage});
        return null;
    }
    return o;
}

/// The modules collected so far, each compiled to a binary chunk.
const Collector = struct {
    gpa: Allocator,
    io: std.Io,
    l: *lus.vm.state.Thread,
    path_templates: []const u8,
    /// The `-P` grants, which also limit compile-time evaluation.
    pledges: []const []const u8 = &.{},
    modules: std.ArrayList(bundle.Module) = .empty,
    /// For each module, in the order of `modules`: the names of its
    /// literal requires and whether it came from an `--include` of a
    /// directory, which makes it a candidate for tree shaking.
    info: std.ArrayList(Info) = .empty,
    /// Whether any collected chunk loads modules dynamically.
    dynamic: bool = false,
    /// Set while a directory of `--include` is being collected.
    in_dir: bool = false,
    /// Resolves the remote modules that literal requires name.
    store: *remote.Store,
    /// Which builtins the collected chunks can reach.
    proof: libproof.Proof,

    const Info = struct { requires: [][]u8, candidate: bool };

    fn deinit(c: *Collector) void {
        for (c.modules.items) |m| {
            c.gpa.free(m.name);
            c.gpa.free(m.chunkname);
            c.gpa.free(m.data);
        }
        c.modules.deinit(c.gpa);
        for (c.info.items) |i| {
            for (i.requires) |r| c.gpa.free(r);
            c.gpa.free(i.requires);
        }
        c.info.deinit(c.gpa);
        c.proof.deinit();
    }

    /// Drops the candidates that no literal require reaches from the
    /// roots, unless some chunk loads modules dynamically. Returns the
    /// number of modules dropped and prints their names.
    fn shake(c: *Collector, io: std.Io) !usize {
        if (c.dynamic) return 0;
        const n = c.modules.items.len;
        const keep = try c.gpa.alloc(bool, n);
        defer c.gpa.free(keep);
        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(c.gpa);
        for (c.info.items, 0..) |i, k| {
            keep[k] = !i.candidate;
            if (keep[k]) try queue.append(c.gpa, k);
        }
        while (queue.pop()) |k| {
            for (c.info.items[k].requires) |r| {
                for (c.modules.items, 0..) |m, j| {
                    if (!keep[j] and std.mem.eql(u8, m.name, r)) {
                        keep[j] = true;
                        try queue.append(c.gpa, j);
                    }
                }
            }
        }
        var dropped: usize = 0;
        var w: usize = 0;
        for (0..n) |k| {
            if (keep[k]) {
                c.modules.items[w] = c.modules.items[k];
                c.info.items[w] = c.info.items[k];
                w += 1;
                continue;
            }
            const m = c.modules.items[k];
            const note = try std.fmt.allocPrint(c.gpa, "left out {s}, which no literal require reaches\n", .{m.name});
            defer c.gpa.free(note);
            std.Io.File.stdout().writeStreamingAll(io, note) catch {};
            c.gpa.free(m.name);
            c.gpa.free(m.chunkname);
            c.gpa.free(m.data);
            for (c.info.items[k].requires) |r| c.gpa.free(r);
            c.gpa.free(c.info.items[k].requires);
            dropped += 1;
        }
        c.modules.shrinkRetainingCapacity(w);
        c.info.shrinkRetainingCapacity(w);
        return dropped;
    }

    fn hasName(c: *Collector, name: []const u8) bool {
        for (c.modules.items) |m| if (std.mem.eql(u8, m.name, name)) return true;
        return false;
    }

    /// Compiles the file at `path` as module `name` and follows its
    /// literal requires. Prints the problem and returns error.Reported on
    /// failure.
    fn add(c: *Collector, name: []const u8, path: []const u8) anyerror!void {
        if (c.hasName(name)) return;

        const src = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .unlimited) catch |e| {
            std.debug.print("lus build: cannot open {s} ({s})\n", .{ path, @errorName(e) });
            return error.Reported;
        };
        defer c.gpa.free(src);
        const chunkname = try std.fmt.allocPrint(c.gpa, "@{s}", .{path});
        errdefer c.gpa.free(chunkname);
        const g = c.l.g;
        const flags: ?*const std.StringHashMapUnmanaged(lus.vm.value.Value) = if (g.ext.get("flags.compile")) |p| @ptrCast(@alignCast(p)) else null;
        const r = try codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flags, .meta_grants = .{ .specs = c.pledges } });
        const proto = switch (r) {
            .err => |msg| {
                defer c.gpa.free(msg);
                std.debug.print("lus build: {s}\n", .{msg});
                return error.Reported;
            },
            .ok => |p| p,
        };
        c.proof.add(proto, chunkname);
        const data = dump.dump(c.gpa, proto, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => {
                std.debug.print("lus build: {s} holds a constant that cannot be bundled\n", .{path});
                return error.Reported;
            },
        };
        errdefer c.gpa.free(data);
        const owned_name = try c.gpa.dupe(u8, name);
        errdefer c.gpa.free(owned_name);

        var required: std.ArrayList([]u8) = .empty;
        errdefer {
            for (required.items) |s| c.gpa.free(s);
            required.deinit(c.gpa);
        }
        {
            var arena_state = std.heap.ArenaAllocator.init(c.gpa);
            defer arena_state.deinit();
            if (try modtree.scan(c.gpa, arena_state.allocator(), src, chunkname)) |sc| {
                if (sc.dynamic) c.dynamic = true;
                for (sc.literal) |lit| try required.append(c.gpa, try c.gpa.dupe(u8, lit));
            }
        }
        try c.modules.append(c.gpa, .{ .name = owned_name, .chunkname = chunkname, .data = data });
        const reqs = try required.toOwnedSlice(c.gpa);
        try c.info.append(c.gpa, .{ .requires = reqs, .candidate = c.in_dir });

        // Modules that a candidate reaches are candidates too, so they
        // stay only when a root reaches them.
        for (reqs) |mod| {
            if (remote.isUrl(mod)) {
                try c.addRemote(mod);
                continue;
            }
            if (c.hasName(mod)) continue;
            const file = try c.resolve(mod) orelse continue;
            defer c.gpa.free(file);
            try c.add(mod, file);
        }
    }

    /// Fetches a remote module and bundles it under its key, as `require`
    /// stores it in `package.loaded`. An atmosphere package contributes
    /// every module of its bundle, compiled with the flags of its package.
    /// A module from a generic server contributes itself and the modules
    /// that its literal requires name.
    fn addRemote(c: *Collector, text: []const u8) anyerror!void {
        var why: std.ArrayList(u8) = .empty;
        defer why.deinit(c.gpa);
        const url = remote.normalize(c.gpa, text, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Remote => {
                std.debug.print("lus build: {s}\n", .{why.items});
                return error.Reported;
            },
        };
        defer c.gpa.free(url);
        if (c.hasName(url)) return;
        c.store.lock();
        const pkg = c.store.get(url, &why) catch |e| {
            c.store.unlock();
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Remote => {
                    std.debug.print("lus build: {s}\n", .{why.items});
                    return error.Reported;
                },
            }
        };
        c.store.unlock();
        if (pkg.kind == .atmosphere) return c.addBundle(pkg, pkg.bundle_dir, "");
        try c.addSource(url, pkg.source, null, null);
        var arena_state = std.heap.ArenaAllocator.init(c.gpa);
        defer arena_state.deinit();
        const sc = (try modtree.scan(c.gpa, arena_state.allocator(), pkg.source, url)) orelse return;
        for (sc.literal) |lit| {
            if (remote.isUrl(lit)) {
                try c.addRemote(lit);
            } else if (!package.answeredEarly(lit)) {
                const rel = try std.mem.replaceOwned(u8, c.gpa, lit, ".", "/");
                defer c.gpa.free(rel);
                const next = try std.mem.concat(c.gpa, u8, &.{ remote.dirOf(url), rel, ".lus" });
                defer c.gpa.free(next);
                try c.addRemote(next);
            }
        }
    }

    /// Bundles every `.lus` file below `dir` of an atmosphere package.
    fn addBundle(c: *Collector, pkg: *remote.Package, dir: []const u8, rel: []const u8) anyerror!void {
        var d = std.Io.Dir.cwd().openDir(c.io, dir, .{ .iterate = true }) catch {
            std.debug.print("lus build: cannot open the cached bundle of {s}\n", .{pkg.url});
            return error.Reported;
        };
        defer d.close(c.io);
        var it = d.iterate();
        while (try it.next(c.io)) |ent| {
            const sub_rel = if (rel.len == 0) try c.gpa.dupe(u8, ent.name) else try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ rel, ent.name });
            defer c.gpa.free(sub_rel);
            const full = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ dir, ent.name });
            defer c.gpa.free(full);
            if (ent.kind == .directory) {
                try c.addBundle(pkg, full, sub_rel);
                continue;
            }
            if (!std.mem.endsWith(u8, ent.name, ".lus")) continue;
            const src = try std.Io.Dir.cwd().readFileAlloc(c.io, full, c.gpa, .unlimited);
            defer c.gpa.free(src);
            if (std.mem.eql(u8, sub_rel, pkg.main)) {
                try c.addSource(pkg.url, src, pkg, null);
                continue;
            }
            // dates/zones.lus is the module dates.zones, dates/init.lus
            // the module dates.
            var stem = sub_rel[0 .. sub_rel.len - 4];
            if (std.mem.endsWith(u8, stem, "/init")) stem = stem[0 .. stem.len - 5];
            const mod = try std.mem.replaceOwned(u8, c.gpa, stem, "/", ".");
            defer c.gpa.free(mod);
            const key = try std.mem.concat(c.gpa, u8, &.{ pkg.url, "#", mod });
            defer c.gpa.free(key);
            try c.addSource(key, src, pkg, mod);
        }
    }

    /// Compiles `src` and bundles it as the module `key`. A module of an
    /// atmosphere package compiles with the flags of its package.
    fn addSource(c: *Collector, key: []const u8, src: []const u8, pkg: ?*remote.Package, sub: ?[]const u8) anyerror!void {
        if (c.hasName(key)) return;
        const chunkname = try std.fmt.allocPrint(c.gpa, "@{s}", .{key});
        errdefer c.gpa.free(chunkname);
        const g = c.l.g;
        var fmap: std.StringHashMapUnmanaged(lus.vm.value.Value) = .empty;
        defer fmap.deinit(c.gpa);
        var fp: std.ArrayList(u8) = .empty;
        defer fp.deinit(c.gpa);
        const top = c.l.top;
        defer c.l.top = top;
        if (pkg) |p| try package.packageFlags(c.l, c.gpa, p, sub, &fmap, &fp);
        const flags: ?*const std.StringHashMapUnmanaged(lus.vm.value.Value) = if (pkg != null) &fmap else if (g.ext.get("flags.compile")) |fl| @ptrCast(@alignCast(fl)) else null;
        const r = try codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flags, .fold_flag_reads = pkg != null, .meta_grants = .{ .specs = c.pledges } });
        const proto = switch (r) {
            .err => |msg| {
                defer c.gpa.free(msg);
                std.debug.print("lus build: {s}\n", .{msg});
                return error.Reported;
            },
            .ok => |p| p,
        };
        c.proof.add(proto, chunkname);
        const data = dump.dump(c.gpa, proto, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => {
                std.debug.print("lus build: {s} holds a constant that cannot be bundled\n", .{key});
                return error.Reported;
            },
        };
        errdefer c.gpa.free(data);
        const owned = try c.gpa.dupe(u8, key);
        errdefer c.gpa.free(owned);
        try c.modules.append(c.gpa, .{ .name = owned, .chunkname = chunkname, .data = data });
        try c.info.append(c.gpa, .{ .requires = &.{}, .candidate = false });
    }

    /// Bundles the update of observed variables as a binary chunk, which
    /// a runtime without the compiler loads in place of compiling it.
    fn addObserveUpdate(c: *Collector) !void {
        const lazy = @import("../lib/lazy.zig");
        const proto = try lazy.compileUpdate(c.l.g);
        const data = dump.dump(c.gpa, proto, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => unreachable,
        };
        errdefer c.gpa.free(data);
        const name = try c.gpa.dupe(u8, lazy.bundle_module);
        errdefer c.gpa.free(name);
        const chunkname = try c.gpa.dupe(u8, "=observe");
        errdefer c.gpa.free(chunkname);
        try c.modules.append(c.gpa, .{ .name = name, .chunkname = chunkname, .data = data });
        try c.info.append(c.gpa, .{ .requires = &.{}, .candidate = false });
    }

    /// Resolves a module name through the path templates, as `require`
    /// does at run time from the same directory.
    fn resolve(c: *Collector, name: []const u8) !?[]u8 {
        const mod = try std.mem.replaceOwned(u8, c.gpa, name, ".", "/");
        defer c.gpa.free(mod);
        var it = std.mem.splitScalar(u8, c.path_templates, ';');
        while (it.next()) |tmpl| {
            if (tmpl.len == 0) continue;
            const file = try std.mem.replaceOwned(u8, c.gpa, tmpl, "?", mod);
            if (std.Io.Dir.cwd().statFile(c.io, file, .{})) |st| {
                if (st.kind != .directory) return file;
            } else |_| {}
            c.gpa.free(file);
        }
        return null;
    }

    /// Adds an `--include` spec: a file, optionally renamed with
    /// `:alias`, or a directory whose modules are named by their path from
    /// the directory's own name.
    fn include(c: *Collector, spec: []const u8) !void {
        const colon = aliasColon(spec);
        const path = if (colon) |k| spec[0..k] else spec;
        if (colon == null) {
            if (std.Io.Dir.cwd().statFile(c.io, path, .{})) |st| {
                if (st.kind == .directory) {
                    const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/\\"));
                    return c.includeDir(path, base);
                }
            } else |_| {}
        }
        if (colon) |k| return c.add(spec[k + 1 ..], path);
        const name = try moduleName(c.gpa, std.fs.path.basename(path), "");
        defer c.gpa.free(name);
        try c.add(name, path);
    }

    fn includeDir(c: *Collector, path: []const u8, prefix: []const u8) !void {
        const was = c.in_dir;
        c.in_dir = true;
        defer c.in_dir = was;
        var dir = std.Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true }) catch {
            std.debug.print("lus build: cannot open directory '{s}'\n", .{path});
            return error.Reported;
        };
        defer dir.close(c.io);
        var it = dir.iterate();
        while (try it.next(c.io)) |ent| {
            if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
            const full = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ path, ent.name });
            defer c.gpa.free(full);
            if (ent.kind == .directory) {
                const sub = try std.fmt.allocPrint(c.gpa, "{s}.{s}", .{ prefix, ent.name });
                defer c.gpa.free(sub);
                try c.includeDir(full, sub);
            } else if (std.mem.endsWith(u8, ent.name, ".lus") or std.mem.endsWith(u8, ent.name, ".lua")) {
                const name = try moduleName(c.gpa, ent.name, prefix);
                defer c.gpa.free(name);
                try c.add(name, full);
            }
        }
    }
};

/// The colon that starts an alias, skipping a Windows drive prefix.
fn aliasColon(spec: []const u8) ?usize {
    const k = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return null;
    if (k == 1 and std.ascii.isAlphabetic(spec[0]) and spec.len > 2 and (spec[2] == '/' or spec[2] == '\\')) return null;
    return k;
}

fn moduleName(gpa: Allocator, file: []const u8, prefix: []const u8) ![]u8 {
    var stem = file;
    if (std.mem.endsWith(u8, stem, ".lus") or std.mem.endsWith(u8, stem, ".lua")) stem = stem[0 .. stem.len - 4];
    if (prefix.len == 0) return gpa.dupe(u8, stem);
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, stem });
}

/// The output path for `script` when `-o` is absent.
fn defaultOutput(gpa: Allocator, script: []const u8) ![]u8 {
    const base = std.fs.path.basename(script);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| (if (d == 0) base else base[0..d]) else base;
    if (builtin.os.tag == .windows) return std.fmt.allocPrint(gpa, "{s}.exe", .{stem});
    if (std.mem.eql(u8, stem, base)) return std.fmt.allocPrint(gpa, "{s}.out", .{stem});
    return gpa.dupe(u8, stem);
}

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var opts = (try parseOptions(gpa, args)) orelse return 2;
    defer opts.deinit(gpa);
    const script = opts.script.?;

    // A state backs compilation, so flags fold exactly as when the script
    // runs. Collection stays off while prototypes wait to be dumped.
    const l = try api.newState(gpa, io);
    defer api.close(l);
    l.g.gc_stopped = true;
    try api.setFlags(l, opts.flags.items);

    const path_templates = if (init.environ_map.get("LUS_PATH")) |p| p else package.default_path;
    const home_dir = lus.home.path(gpa, init.environ_map) catch null;
    defer if (home_dir) |h| gpa.free(h);
    var store: remote.Store = .init(gpa, io, .{ .home = home_dir, .env = init.environ_map });
    defer store.deinit();
    var c: Collector = .{ .gpa = gpa, .io = io, .l = l, .path_templates = path_templates, .store = &store, .pledges = opts.pledges.items, .proof = .init(gpa) };
    defer c.deinit();
    // The entry module is named after the script, as a module file of
    // that name would be.
    const entry_name = try moduleName(gpa, std.fs.path.basename(script), "");
    defer gpa.free(entry_name);
    c.add(entry_name, script) catch |e| {
        if (e == error.Reported) return 1;
        return e;
    };
    for (opts.includes.items) |spec| {
        c.include(spec) catch |e| {
            if (e == error.Reported) return 1;
            return e;
        };
    }
    _ = try c.shake(io);
    // A runtime without the compiler reads the update of observed
    // variables from the bundle.
    if (opts.aot or opts.runtime != null or opts.link_object != null) try c.addObserveUpdate();

    // The preserved options, applied before the program runs.
    var preserved: std.ArrayList([]const u8) = .empty;
    defer preserved.deinit(gpa);
    for (opts.pledges.items) |p| try preserved.appendSlice(gpa, &.{ "-P", p });
    for (opts.flags.items) |f| try preserved.appendSlice(gpa, &.{ "-F", f });

    const out_path = if (opts.output) |o| try gpa.dupe(u8, o) else try defaultOutput(gpa, script);
    defer gpa.free(out_path);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    var linked: ?LinkNote = null;
    if (!opts.aot) {
        // The program part of the running executable, or of the runtime
        // that --runtime names, without any bundle it already carries, or
        // an executable linked from the link object.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try bundle.write(gpa, &payload, preserved.items, c.modules.items, 0);
        if (opts.link_object) |lo| {
            linked = (try linkImage(io, gpa, lo, &c.proof, opts.link_all, opts.link_map, null, payload.items, &image)) orelse return 1;
        } else {
            if (!try readProgram(io, gpa, opts.runtime, &image)) return 1;
            if (!try attach(gpa, &image, payload.items)) return 1;
        }
    } else {
        // A bundle on the running lus runs once under the training
        // setting and writes the code section of what it compiled
        // (`spec/design/aot.md`).
        if (!jit.enabled) {
            std.debug.print("lus build: --aot compiles from a training run of the JIT, and this lus has no JIT for {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
            return 1;
        }
        const section = (try train(init, gpa, preserved.items, c.modules.items, out_path, opts.train, opts.static)) orelse return 1;
        defer gpa.free(section);
        const base: ?[]const u8 = if (opts.keep_jit) null else opts.runtime orelse blk: {
            const dir = std.process.executableDirPathAlloc(io, gpa) catch {
                std.debug.print("lus build: cannot find the directory of the running executable\n", .{});
                return 1;
            };
            defer gpa.free(dir);
            break :blk try std.fs.path.join(gpa, &.{ dir, if (builtin.os.tag == .windows) "lus-runtime.exe" else "lus-runtime" });
        };
        defer if (base) |b| if (opts.runtime == null) gpa.free(b);
        // Releases ship the link object of the runtime next to it, named
        // without the extension of an executable.
        const default_lo = if (base) |b| try std.fmt.allocPrint(gpa, "{s}.lo", .{if (std.mem.endsWith(u8, b, ".exe")) b[0 .. b.len - 4] else b}) else null;
        defer if (default_lo) |d| gpa.free(d);
        const lo_path = opts.link_object orelse if (default_lo) |d| (if (exists(io, d)) d else null) else null;
        var modules: std.ArrayList(bundle.Module) = .empty;
        defer modules.deinit(gpa);
        try modules.appendSlice(gpa, c.modules.items);
        try modules.append(gpa, .{ .name = ".aot", .chunkname = "=aot", .data = section });
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try bundle.write(gpa, &payload, preserved.items, modules.items, 0);
        if (lo_path) |lo| {
            linked = (try linkImage(io, gpa, lo, &c.proof, opts.link_all, opts.link_map, section, payload.items, &image)) orelse return 1;
        } else {
            if (!try readProgram(io, gpa, base, &image)) return 1;
            if (!try attach(gpa, &image, payload.items)) return 1;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, out_path, .{ .permissions = .executable_file }) catch |e| {
        std.debug.print("lus build: cannot create {s} ({s})\n", .{ out_path, @errorName(e) });
        return 1;
    };
    defer file.close(io);
    file.writeStreamingAll(io, image.items) catch |e| {
        std.debug.print("lus build: cannot write {s} ({s})\n", .{ out_path, @errorName(e) });
        return 1;
    };
    // The modules whose names start with a dot belong to the runtime.
    var user_modules: usize = 0;
    for (c.modules.items) |m| {
        if (!std.mem.startsWith(u8, m.name, ".")) user_modules += 1;
    }
    const note = if (linked) |ln|
        try std.fmt.allocPrint(gpa, "wrote {s} ({d} modules, {d} KB of the {d} KB runtime linked)\n", .{ out_path, user_modules, ln.kept / 1024, ln.total / 1024 })
    else
        try std.fmt.allocPrint(gpa, "wrote {s} ({d} modules)\n", .{ out_path, user_modules });
    defer gpa.free(note);
    std.Io.File.stdout().writeStreamingAll(io, note) catch {};
    return 0;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const LinkNote = struct { kept: u64, total: u64 };

/// Links the executable from the link object at `path` into `image`,
/// keeping the builtins that `proof` reaches, every builtin when `all` is
/// set, and the builtins that the code section `section` calls. Prints
/// the reason and returns null when it cannot.
fn linkImage(io: std.Io, gpa: Allocator, path: []const u8, proof: *libproof.Proof, all: bool, map_path: ?[]const u8, section: ?[]const u8, payload: []const u8, image: *std.ArrayList(u8)) !?LinkNote {
    const data = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .@"8", null) catch |e| {
        std.debug.print("lus build: cannot read the link object {s} ({s})\n", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(data);
    const o = lobj.read(data) catch {
        std.debug.print("lus build: {s} is not a link object\n", .{path});
        return null;
    };
    if (section) |sec| {
        const host_arch: ?lobj.Arch = switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .arm => .arm,
            .riscv64 => .riscv64,
            .loongarch64 => .loongarch64,
            .powerpc64le => .powerpc64le,
            .s390x => .s390x,
            else => null,
        };
        const host_os: ?lobj.Os = switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .freebsd => .freebsd,
            else => null,
        };
        // iOS runs the code that a training run on macOS compiled in the
        // static form, on the same architecture and calling convention.
        const ios_ok = o.os.iphone() and host_os == .macos and aot.sectionStatic(sec);
        if (o.os.iphone() and !aot.sectionStatic(sec)) {
            std.debug.print("lus build: iOS runs only code compiled ahead of time in the static form (--aot-static)\n", .{});
            return null;
        }
        if (host_arch != o.arch or (host_os != o.os and !ios_ok)) {
            std.debug.print("lus build: the link object {s} is for {s}-{s}, and code compiled ahead of time runs only where it was trained\n", .{ path, @tagName(o.arch), @tagName(o.os) });
            return null;
        }
        aot.sectionStrings(sec, proof, struct {
            fn f(pr: *libproof.Proof, str: []const u8) void {
                pr.reach(str);
            }
        }.f);
    }
    if (!all) if (proof.failed) |f| {
        std.debug.print("lus build: kept every builtin: {s}:{d}: {s}\n", .{ f.chunk, f.line, f.why });
    };
    const keep: linker.Keep = if (all) .all else .{ .ctx = proof, .keeps = struct {
        fn f(ctx: *const anyopaque, kind: lobj.GuardKind, p: []const u8, name: []const u8) bool {
            const pr: *const libproof.Proof = @ptrCast(@alignCast(ctx));
            return pr.keeps(@fromBackingInt(@intCast(@backingInt(kind))), p, name);
        }
    }.f };
    var map_buf: [4096]u8 = undefined;
    var map_file: ?std.Io.File = null;
    defer if (map_file) |f| f.close(io);
    var map_writer: ?std.Io.File.Writer = null;
    if (map_path) |mp| {
        map_file = std.Io.Dir.cwd().createFile(io, mp, .{}) catch |e| {
            std.debug.print("lus build: cannot create {s} ({s})\n", .{ mp, @errorName(e) });
            return null;
        };
        map_writer = map_file.?.writer(io, &map_buf);
    }
    // A static section becomes atoms of the image.
    var merged: ?[]align(8) u8 = null;
    defer if (merged) |m| gpa.free(m);
    var obj = o;
    if (section) |sec| if (aot.sectionStatic(sec)) {
        merged = staticObject(gpa, &o, sec) catch |e| {
            std.debug.print("lus build: cannot link the code compiled ahead of time into the executable ({s})\n", .{@errorName(e)});
            return null;
        };
        obj = lobj.read(merged.?) catch {
            std.debug.print("lus build: cannot link the code compiled ahead of time into the executable\n", .{});
            return null;
        };
    };
    const r = linker.link(gpa, &obj, keep, .{ .map = if (map_writer) |*mw| &mw.interface else null, .payload = payload }) catch |e| {
        std.debug.print("lus build: cannot link {s} ({s})\n", .{ path, @errorName(e) });
        return null;
    };
    defer gpa.free(r.bytes);
    try image.appendSlice(gpa, r.bytes);
    return .{ .kept = r.kept, .total = r.total };
}

/// The link object `o` with the code of the static section `sec` as atoms
/// (`spec/design/aot.md`, "The linker"): one atom of code, where each pair
/// of `adr` and `ldr` becomes `adrp` and `ldr` of a slot, the zeroed
/// slots, and the variable `lus_aot_image` of the runtime pointing at
/// both.
fn staticObject(gpa: Allocator, o: *const lobj.Object, sec: []const u8) ![]align(8) u8 {
    if (o.arch != .aarch64) return error.UnsupportedTarget;
    var w = try lobj.Writer.fromObject(gpa, o);
    defer w.deinit();
    const holder = for (o.atoms, 0..) |a, i| {
        if (std.mem.eql(u8, o.string(a.name), "lus_aot_image")) break i;
    } else return error.NoImageVariable;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var relocs: std.ArrayList(lobj.Reloc) = .empty;
    defer relocs.deinit(gpa);
    const slots_atom: u32 = @intCast(w.atoms.items.len + 1);
    var it = aot.StaticIter.init(sec) orelse return error.BadSection;
    var nslots: u32 = 0;
    while (it.next()) |x| {
        try code.appendNTimes(gpa, 0, @intCast(x.code_off - code.items.len));
        try code.appendSlice(gpa, x.code);
        const n = x.relocs.len / 20;
        for (0..n) |k| {
            const e = x.relocs[k * 20 ..][0..20];
            if (e[4] != @backingInt(reloc.Form.slot)) return error.NotStatic;
            const at: u32 = @intCast(x.code_off + std.mem.readInt(u32, e[0..4], .little));
            // adr becomes adrp, whose immediate the linker writes.
            const insn = std.mem.readInt(u32, code.items[at..][0..4], .little);
            std.mem.writeInt(u32, code.items[at..][0..4], (insn & 0x1f) | 0x9000_0000, .little);
            const slot: u32 = 8 * (x.slot_base + @as(u32, @intCast(k)));
            const t: lobj.Target = .{ .index = @intCast(slots_atom), .space = .atom };
            try relocs.append(gpa, .{ .offset = at, .type = 275, .target = t, .sym = slot, .addend = 0 });
            try relocs.append(gpa, .{ .offset = at + 4, .type = 286, .target = t, .sym = slot, .addend = 0 });
        }
        nslots = x.slot_base + @as(u32, @intCast(n));
    }
    const code_atom = try w.atom(.text, 4, code.items, @intCast(code.items.len), "lus.aot.code");
    for (relocs.items) |rl| try w.reloc(rl);
    if (try w.atom(.bss, 3, null, @max(8, 8 * nslots), "lus.aot.slots") != slots_atom) unreachable;
    // The variable of the runtime holds the addresses of both.
    while (w.data.items.len % 8 != 0) try w.data.append(gpa, 0);
    const h = &w.atoms.items[holder];
    h.kind = .data;
    h.data = @intCast(w.data.items.len);
    try w.data.appendNTimes(gpa, 0, h.size);
    h.first_reloc = @intCast(w.relocs.items.len);
    h.relocs = 2;
    try w.relocs.append(gpa, .{ .offset = 0, .type = 257, .target = .{ .index = @intCast(code_atom), .space = .atom }, .addend = 0 });
    try w.relocs.append(gpa, .{ .offset = 8, .type = 257, .target = .{ .index = @intCast(slots_atom), .space = .atom }, .addend = 0 });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try w.write(&out.writer);
    const bytes = try gpa.alignedAlloc(u8, .@"8", out.written().len);
    @memcpy(bytes, out.written());
    return bytes;
}

/// Adds the bundle `payload` to the executable in `image`: into a segment
/// of a Mach-O executable, which is signed again, or after any other.
/// Prints the reason and returns false when it cannot.
fn attach(gpa: Allocator, image: *std.ArrayList(u8), payload: []const u8) !bool {
    if (image.items.len < 4 or std.mem.readInt(u32, image.items[0..4], .little) != 0xfeedfacf) {
        try image.appendSlice(gpa, payload);
        return true;
    }
    const out = macho.embed(gpa, image.items, payload) catch |e| {
        std.debug.print("lus build: cannot put the bundle into the executable ({s})\n", .{@errorName(e)});
        return false;
    };
    defer gpa.free(out);
    image.clearRetainingCapacity();
    try image.appendSlice(gpa, out);
    return true;
}

/// Reads the program part of `path`, or of the running executable when
/// `path` is null, without any bundle it carries, into `image`. Prints
/// the reason and returns false when it cannot.
fn readProgram(io: std.Io, gpa: Allocator, path: ?[]const u8, image: *std.ArrayList(u8)) !bool {
    const self = if (path) |rp| std.Io.Dir.cwd().openFile(io, rp, .{}) catch |e| {
        std.debug.print("lus build: cannot open the runtime {s} ({s})\n", .{ rp, @errorName(e) });
        return false;
    } else std.process.openExecutable(io, .{}) catch |e| {
        std.debug.print("lus build: cannot open the running executable ({s})\n", .{@errorName(e)});
        return false;
    };
    defer self.close(io);
    const prog_len = bundle.programLength(io, self) catch |e| {
        std.debug.print("lus build: cannot read the executable ({s})\n", .{@errorName(e)});
        return false;
    };
    try image.resize(gpa, @intCast(prog_len));
    const n = self.readPositionalAll(io, image.items, 0) catch |e| {
        std.debug.print("lus build: cannot read the executable ({s})\n", .{@errorName(e)});
        return false;
    };
    if (n != prog_len) {
        std.debug.print("lus build: cannot read the executable\n", .{});
        return false;
    }
    return true;
}

/// Writes a bundle on the running lus next to `out_path`, runs it with the
/// training arguments under `LUS_JIT_AOT=train:` with the default JIT, and
/// returns the code section that it wrote, or null after printing why.
fn train(init: std.process.Init, gpa: Allocator, preserved: []const []const u8, modules: []const bundle.Module, out_path: []const u8, args: ?[]const u8, static: bool) !?[]u8 {
    const io = init.io;
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    if (!try readProgram(io, gpa, null, &image)) return null;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try bundle.write(gpa, &payload, preserved, modules, 0);
    if (!try attach(gpa, &image, payload.items)) return null;
    const exe = try std.fmt.allocPrint(gpa, "{s}.train", .{out_path});
    defer gpa.free(exe);
    const sec = try std.fmt.allocPrint(gpa, "{s}.aot", .{out_path});
    defer gpa.free(sec);
    const cwd = std.Io.Dir.cwd();
    {
        const file = cwd.createFile(io, exe, .{ .permissions = .executable_file }) catch |e| {
            std.debug.print("lus build: cannot create {s} ({s})\n", .{ exe, @errorName(e) });
            return null;
        };
        defer file.close(io);
        file.writeStreamingAll(io, image.items) catch |e| {
            std.debug.print("lus build: cannot write {s} ({s})\n", .{ exe, @errorName(e) });
            return null;
        };
    }
    defer cwd.deleteFile(io, exe) catch {};
    defer cwd.deleteFile(io, sec) catch {};
    var env = try init.environ_map.clone(gpa);
    defer env.deinit();
    const setting = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ if (static) "train+static" else "train", sec });
    defer gpa.free(setting);
    try env.put("LUS_JIT_AOT", setting);
    // The training run compiles as the JIT does by default.
    _ = env.swapRemove("LUS_JIT");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    const exe_arg = if (std.fs.path.isAbsolute(exe) or std.mem.indexOfScalar(u8, exe, '/') != null) exe else try std.fmt.allocPrint(gpa, "./{s}", .{exe});
    defer if (exe_arg.ptr != exe.ptr) gpa.free(exe_arg);
    try argv.append(gpa, exe_arg);
    if (args) |a| {
        var it = std.mem.tokenizeScalar(u8, a, ' ');
        while (it.next()) |x| try argv.append(gpa, x);
    }
    var child = std.process.spawn(io, .{ .argv = argv.items, .environ_map = &env }) catch |e| {
        std.debug.print("lus build: cannot run the training bundle ({s})\n", .{@errorName(e)});
        return null;
    };
    const term = child.wait(io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("lus build: the training run exited with status {d}\n", .{code});
            return null;
        },
        else => {
            std.debug.print("lus build: the training run did not exit normally\n", .{});
            return null;
        },
    }
    return cwd.readFileAlloc(io, sec, gpa, .unlimited) catch |e| {
        std.debug.print("lus build: the training run wrote no code section ({s})\n", .{@errorName(e)});
        return null;
    };
}
