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
    \\
;

const Options = struct {
    output: ?[]const u8 = null,
    script: ?[]const u8 = null,
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
        const Kind = enum { output, pledge, flag, include };
        const kind: ?Kind = if (std.mem.eql(u8, a, "-o"))
            .output
        else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--pledge"))
            .pledge
        else if (std.mem.eql(u8, a, "-F") or std.mem.eql(u8, a, "--flag"))
            .flag
        else if (std.mem.eql(u8, a, "--include"))
            .include
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
        const r = try codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flags });
        const proto = switch (r) {
            .err => |msg| {
                defer c.gpa.free(msg);
                std.debug.print("lus build: {s}\n", .{msg});
                return error.Reported;
            },
            .ok => |p| p,
        };
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
        if (pkg) |p| try package.packageFlags(c.l, p, sub, &fmap, &fp);
        const flags: ?*const std.StringHashMapUnmanaged(lus.vm.value.Value) = if (pkg != null) &fmap else if (g.ext.get("flags.compile")) |fl| @ptrCast(@alignCast(fl)) else null;
        const r = try codegen.compile(g, src, .{ .chunkname = chunkname, .flags = flags, .fold_flag_reads = pkg != null });
        const proto = switch (r) {
            .err => |msg| {
                defer c.gpa.free(msg);
                std.debug.print("lus build: {s}\n", .{msg});
                return error.Reported;
            },
            .ok => |p| p,
        };
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
    var c: Collector = .{ .gpa = gpa, .io = io, .l = l, .path_templates = path_templates, .store = &store };
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

    // The preserved options, applied before the program runs.
    var preserved: std.ArrayList([]const u8) = .empty;
    defer preserved.deinit(gpa);
    for (opts.pledges.items) |p| try preserved.appendSlice(gpa, &.{ "-P", p });
    for (opts.flags.items) |f| try preserved.appendSlice(gpa, &.{ "-F", f });

    // The program part of the running executable, without any bundle it
    // already carries.
    const self = std.process.openExecutable(io, .{}) catch |e| {
        std.debug.print("lus build: cannot open the running executable ({s})\n", .{@errorName(e)});
        return 1;
    };
    defer self.close(io);
    const prog_len = bundle.programLength(io, self) catch |e| {
        std.debug.print("lus build: cannot read the running executable ({s})\n", .{@errorName(e)});
        return 1;
    };
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.resize(gpa, @intCast(prog_len));
    const n = self.readPositionalAll(io, image.items, 0) catch |e| {
        std.debug.print("lus build: cannot read the running executable ({s})\n", .{@errorName(e)});
        return 1;
    };
    if (n != prog_len) {
        std.debug.print("lus build: cannot read the running executable\n", .{});
        return 1;
    }
    try bundle.write(gpa, &image, preserved.items, c.modules.items, 0);

    const out_path = if (opts.output) |o| try gpa.dupe(u8, o) else try defaultOutput(gpa, script);
    defer gpa.free(out_path);
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
    const note = try std.fmt.allocPrint(gpa, "wrote {s} ({d} modules)\n", .{ out_path, c.modules.items.len });
    defer gpa.free(note);
    std.Io.File.stdout().writeStreamingAll(io, note) catch {};
    return 0;
}
