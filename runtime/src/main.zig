//! The `lus` command line interface.
//!
//!   lus [options] [script [args]]
//!   lus <command> [arguments]
//!
//! Commands: run (default), test, fmt, check, ast, doc, debug, build,
//! compile, help, agents.

const std = @import("std");
const pledge = @import("lus").vm.pledge;
const lus = @import("lus");
const api = lus.api;
const out = lus.lib.out;
const package = lus.lib.package;
const Value = lus.vm.value.Value;
const Thread = lus.vm.state.Thread;

pub const version = api.version;

const usage =
    \\usage: lus [options] [script [args]]
    \\       lus <command> [arguments]
    \\
    \\Commands:
    \\  run       run a script (default)
    \\  test      run tests (*_test.lus files and *_test functions)
    \\  fmt       format source files
    \\  check     check source files for errors and lint warnings
    \\  ast       print the syntax tree of a file as JSON
    \\  doc       generate API documentation from doc comments
    \\  debug     run a script under the debug adapter protocol
    \\  build     bundle a script into a standalone executable
    \\  compile   compile a script to a binary chunk
    \\  help      print the standard library reference for a name
    \\  agents    set a project up for coding agents (agents init)
    \\
    \\Options:
    \\  -e stat          execute string 'stat'
    \\  -i               enter interactive mode after running 'script'
    \\  -l mod           require library 'mod' into global 'mod'
    \\  -l g=mod         require library 'mod' into global 'g'
    \\  -v, --version    show version information
    \\  -h, --help       show this help
    \\  -E               ignore environment variables
    \\  -W               turn warnings on
    \\  -P perm          grant a permission (also --pledge perm)
    \\  -F name[=value]  define a compile-time flag (also --flag)
    \\  --include path[:alias]
    \\                   preinclude a module file or directory for require
    \\  --readonly-env   freeze the global environment after startup
    \\  --offline        load remote modules only from the module cache
    \\  --reload         revalidate every remote module before the run
    \\  --no-prefetch    fetch remote modules at their require
    \\  --gc-pause N     heap growth before a collection, in percent
    \\  --dis            print bytecode instead of running
    \\  --               stop handling options
    \\  -                stop handling options and run standard input
    \\
;

const Action = union(enum) {
    exec: []const u8,
    require: []const u8,
};

const Cli = struct {
    actions: std.ArrayList(Action) = .empty,
    pledges: std.ArrayList([]const u8) = .empty,
    flags: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    script: ?[]const u8 = null,
    script_index: usize = 0,
    interactive: bool = false,
    version: bool = false,
    help: bool = false,
    ignore_env: bool = false,
    warnings: bool = false,
    stdin: bool = false,
    dis: bool = false,
    readonly_env: bool = false,
    gc_pause: ?usize = null,
    offline: bool = false,
    reload: bool = false,
    no_prefetch: bool = false,
};

const OptSpec = struct {
    short: ?[]const u8,
    long: ?[]const u8,
    takes_arg: bool,
    apply: *const fn (*Cli, std.mem.Allocator, ?[]const u8) anyerror!void,
};

fn optExec(c: *Cli, a: std.mem.Allocator, v: ?[]const u8) !void {
    try c.actions.append(a, .{ .exec = v.? });
}
fn optRequire(c: *Cli, a: std.mem.Allocator, v: ?[]const u8) !void {
    try c.actions.append(a, .{ .require = v.? });
}
fn optInteractive(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.interactive = true;
}
fn optHelp(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.help = true;
}
fn optVersion(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.version = true;
}
fn optIgnoreEnv(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.ignore_env = true;
}
fn optWarn(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.warnings = true;
}
fn optPledge(c: *Cli, a: std.mem.Allocator, v: ?[]const u8) !void {
    try c.pledges.append(a, v.?);
}
fn optFlag(c: *Cli, a: std.mem.Allocator, v: ?[]const u8) !void {
    try c.flags.append(a, v.?);
}
fn optInclude(c: *Cli, a: std.mem.Allocator, v: ?[]const u8) !void {
    try c.includes.append(a, v.?);
}
fn optGcPause(c: *Cli, _: std.mem.Allocator, v: ?[]const u8) !void {
    c.gc_pause = try std.fmt.parseInt(usize, v.?, 10);
}
fn optDis(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.dis = true;
}
fn optReadonlyEnv(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.readonly_env = true;
}
fn optOffline(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.offline = true;
}
fn optReload(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.reload = true;
}
fn optNoPrefetch(c: *Cli, _: std.mem.Allocator, _: ?[]const u8) !void {
    c.no_prefetch = true;
}

/// The single option table. Short options with arguments accept both
/// "-e stat" and "-estat".
const options = [_]OptSpec{
    .{ .short = "e", .long = null, .takes_arg = true, .apply = optExec },
    .{ .short = "l", .long = null, .takes_arg = true, .apply = optRequire },
    .{ .short = "i", .long = null, .takes_arg = false, .apply = optInteractive },
    .{ .short = "v", .long = "version", .takes_arg = false, .apply = optVersion },
    .{ .short = "h", .long = "help", .takes_arg = false, .apply = optHelp },
    .{ .short = "E", .long = null, .takes_arg = false, .apply = optIgnoreEnv },
    .{ .short = "W", .long = null, .takes_arg = false, .apply = optWarn },
    .{ .short = "P", .long = "pledge", .takes_arg = true, .apply = optPledge },
    .{ .short = "F", .long = "flag", .takes_arg = true, .apply = optFlag },
    .{ .short = null, .long = "include", .takes_arg = true, .apply = optInclude },
    .{ .short = null, .long = "gc-pause", .takes_arg = true, .apply = optGcPause },
    .{ .short = null, .long = "dis", .takes_arg = false, .apply = optDis },
    .{ .short = null, .long = "readonly-env", .takes_arg = false, .apply = optReadonlyEnv },
    .{ .short = null, .long = "offline", .takes_arg = false, .apply = optOffline },
    .{ .short = null, .long = "reload", .takes_arg = false, .apply = optReload },
    .{ .short = null, .long = "no-prefetch", .takes_arg = false, .apply = optNoPrefetch },
};

fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8, start: usize) !?Cli {
    var c: Cli = .{};
    var i = start;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-")) {
            c.stdin = true;
            c.script_index = i;
            return c;
        }
        if (a.len < 2 or a[0] != '-') break;
        var matched = false;
        for (options) |o| {
            if (a[1] == '-') {
                const name = a[2..];
                const ln = o.long orelse continue;
                if (std.mem.startsWith(u8, name, ln) and (name.len == ln.len or name[ln.len] == '=')) {
                    var val: ?[]const u8 = null;
                    if (o.takes_arg) {
                        if (name.len > ln.len) {
                            val = name[ln.len + 1 ..];
                        } else {
                            i += 1;
                            if (i >= args.len) return badOption(a, "needs argument");
                            val = args[i];
                        }
                    }
                    try o.apply(&c, gpa, val);
                    matched = true;
                    break;
                }
            } else {
                const sn = o.short orelse continue;
                if (a[1] != sn[0]) continue;
                var val: ?[]const u8 = null;
                if (o.takes_arg) {
                    if (a.len > 2) {
                        val = a[2..];
                    } else {
                        i += 1;
                        if (i >= args.len) return badOption(a, "needs argument");
                        val = args[i];
                    }
                } else if (a.len > 2) continue;
                try o.apply(&c, gpa, val);
                matched = true;
                break;
            }
        }
        if (!matched) return badOption(a, "unrecognized option");
    }
    if (i < args.len) {
        c.script = args[i];
        c.script_index = i;
    }
    return c;
}

fn badOption(opt: []const u8, what: []const u8) ?Cli {
    std.debug.print("lus: {s} '{s}'\n{s}", .{ what, opt, usage });
    return null;
}

pub fn main(process_init: std.process.Init) !u8 {
    var init = process_init;
    if (lus.vm.faultio.enabled) setupFailIo(&init);
    const gpa = init.gpa;
    if (lus.vm.heapcount.fail_alloc) setupFailAlloc(init);
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    while (it.next()) |a| try args_list.append(gpa, a);
    const args = args_list.items;

    // A standalone executable made by `lus build` runs its bundle and
    // nothing else.
    var found = lus.bundle.loadSelf(init.io, gpa) catch {
        std.debug.print("lus: cannot load the embedded bundle\n", .{});
        return 1;
    };
    if (found) |*b| {
        defer b.deinit(gpa);
        return runBundle(init, b, args);
    }

    // `lus +REQUEST ARGS...` runs another installed version. Only the
    // first argument is read this way (`spec/tools/version.md`).
    if (args.len >= 2 and args[1].len > 1 and args[1][0] == '+') {
        return lus.tools.plus(init, args[1][1..], args[2..]);
    }

    // Subcommands.
    if (args.len >= 2) {
        const cmd = args[1];
        const tools = [_][]const u8{ "test", "fmt", "check", "ast", "doc", "debug", "build", "compile", "help", "agents", "version" };
        for (tools) |t| {
            if (std.mem.eql(u8, cmd, t)) {
                defer reportAllocs();
                return lus.tools.run(init, cmd, args[2..]);
            }
        }
        if (std.mem.eql(u8, cmd, "run")) return profiled(runMain(init, args, 2, null));
    }
    return profiled(runMain(init, args, 1, null));
}

/// Reads `LUS_FAIL_ALLOC` in a `-Dfail-alloc=true` build. `N` fails the
/// Nth allocation of the process, `N+` fails it and every later one, and
/// `count` fails none and prints how many allocations the run made when it
/// exits.
fn setupFailAlloc(init: std.process.Init) void {
    const inject = lus.vm.heapcount.inject;
    inject.trace = init.environ_map.get("LUS_FAIL_ALLOC_TRACE") != null;
    const v = init.environ_map.get("LUS_FAIL_ALLOC") orelse return;
    if (std.mem.eql(u8, v, "count")) {
        report_allocs = true;
        return;
    }
    const sticky = std.mem.endsWith(u8, v, "+");
    inject.target = std.fmt.parseInt(usize, if (sticky) v[0 .. v.len - 1] else v, 10) catch return;
    inject.sticky = sticky;
}

var report_allocs = false;
var report_io = false;

/// Reads `LUS_FAIL_IO` in a `-Dfail-io=true` build and gives the process
/// an `Io` that injects the faults it names (`vm/faultio.zig`).
fn setupFailIo(init: *std.process.Init) void {
    const v = init.environ_map.get("LUS_FAIL_IO") orelse return;
    report_io = lus.vm.faultio.setup(v);
    init.io = lus.vm.faultio.wrap(init.io);
}

fn reportAllocs() void {
    if (report_allocs) std.debug.print("lus: {d} allocations\n", .{lus.vm.heapcount.inject.count.load(.monotonic)});
    if (report_io) std.debug.print("lus: {d} I/O operations\n", .{lus.vm.faultio.count.load(.monotonic)});
}

/// Prints the opcode sequences a run counted, in a build that counts
/// them (`-Dop-profile=true`), and passes the result of the run on.
fn profiled(result: anyerror!u8) anyerror!u8 {
    lus.vm.opprofile.dump();
    reportAllocs();
    return exitAfterWorkers(result);
}

/// Ends the process at once when a worker did not stop as the state
/// closed, which ends the thread of that worker too. A normal return
/// would free memory that the worker may still use.
fn exitAfterWorkers(result: anyerror!u8) anyerror!u8 {
    lus.lib.term.restore();
    if (api.workers_abandoned) std.process.exit(result catch 1);
    return result;
}

/// Runs the entry module of a bundle. The options preserved at build time
/// come first, then the executable path takes the place of the script, so
/// every user argument reaches the script and none is read as an option.
fn runBundle(init: std.process.Init, b: *const lus.bundle.Bundle, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    const self = if (args.len > 0) args[0] else "lus";
    try argv.append(gpa, self);
    try argv.appendSlice(gpa, b.args);
    try argv.appendSlice(gpa, &.{ "--", self });
    if (args.len > 1) try argv.appendSlice(gpa, args[1..]);
    package.bundle = b;
    defer package.bundle = null;
    return exitAfterWorkers(runMain(init, argv.items, 1, b.entryModule()));
}

fn runMain(init: std.process.Init, args: []const []const u8, start: usize, entry: ?lus.bundle.Module) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var cli = (try parseArgs(gpa, args, start)) orelse return 1;
    defer cli.actions.deinit(gpa);
    defer cli.pledges.deinit(gpa);
    defer cli.flags.deinit(gpa);
    defer cli.includes.deinit(gpa);
    if (cli.help) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    if (cli.version) {
        std.debug.print("{s}\n", .{version});
        if (cli.script == null and cli.actions.items.len == 0 and !cli.interactive) return 0;
    }

    // Preincluded sources are read before any state exists, under the
    // full authority of the command line.
    var preinc: Preincludes = .{ .gpa = gpa, .io = io };
    defer preinc.deinit();
    for (cli.includes.items) |spec| {
        preinc.add(spec) catch |e| {
            if (e != error.Reported) std.debug.print("lus: not enough memory for preinclusion\n", .{});
            return 1;
        };
    }
    package.preincludes = preinc.list.items;
    defer package.preincludes = &.{};

    // The store of remote modules and the index of the require tree
    // outlive the state, because workers read them until the state stops
    // them.
    var remote_process: lus.remote.Process = undefined;
    remote_process.begin(gpa, io, init.environ_map, .{ .ignore_env = cli.ignore_env, .offline = cli.offline, .reload = cli.reload });
    defer remote_process.end();
    const store = &remote_process.store;
    var index: ?*lus.modtree.Index = null;
    defer if (index) |x| dropIndex(gpa, x);

    const l = try api.newState(gpa, io);
    defer api.closeForExit(l);
    defer out.deinit(l.g);
    if (!cli.ignore_env) l.g.environ = init.environ_map;
    l.g.args = args;
    l.g.warn_on = cli.warnings;
    if (cli.gc_pause) |p| l.g.pause = p;
    try api.setFlags(l, cli.flags.items);
    api.openLibs(l) catch {
        std.debug.print("lus: cannot open libraries\n", .{});
        return 1;
    };
    package.installPreincludes(l) catch {
        reportError(l);
        return 1;
    };
    api.grantPledges(l, cli.pledges.items) catch {
        reportError(l);
        return 1;
    };
    // The `arg` table.
    try setArgTable(l, args, cli.script_index, cli.script != null or cli.stdin);
    if (cli.readonly_env) api.freezeEnv(l);

    for (cli.actions.items) |a| switch (a) {
        .exec => |src| if (!runString(l, src, "=(command line)")) return 1,
        .require => |spec| {
            var gname = spec;
            var mod = spec;
            if (std.mem.indexOfScalar(u8, spec, '=')) |eq| {
                gname = spec[0..eq];
                mod = spec[eq + 1 ..];
            }
            const code = try std.fmt.allocPrint(gpa, "{s} = require(\"{s}\")", .{ gname, mod });
            defer gpa.free(code);
            if (!runString(l, code, "=(command line)")) return 1;
        },
    };

    if (entry) |m| {
        if (!runChunk(l, m.data, m.chunkname, args[cli.script_index + 1 ..])) return 1;
    } else if (cli.script) |path| {
        if (cli.dis) return disassemble(l, path);
        // When the host limits file reads with -P, the entry script itself
        // must fall within the grant.
        if (limitsFileReads(cli.pledges.items) and !pledge.allowed(l, "fs:read", path)) {
            std.debug.print("lus: permission \"fs:read\" denied for '{s}'\n", .{path});
            return 1;
        }
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            std.debug.print("lus: cannot open {s} ({s})\n", .{ path, @errorName(e) });
            return 1;
        };
        defer gpa.free(src);
        const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{path});
        defer gpa.free(chunkname);
        index = indexTree(l, src, chunkname, &cli);
        store.running = true;
        if (!runChunk(l, src, chunkname, args[cli.script_index + 1 ..])) return 1;
    } else if (cli.stdin) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var rbuf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
        r.interface.appendRemainingUnlimited(gpa, &buf) catch {};
        index = indexTree(l, buf.items, "=stdin", &cli);
        store.running = true;
        if (!runChunk(l, buf.items, "=stdin", args[cli.script_index + 1 ..])) return 1;
    }
    if (cli.interactive or (cli.script == null and !cli.stdin and cli.actions.items.len == 0 and !cli.version)) {
        try repl(l, io);
    }
    return 0;
}

/// The modules named by `--include`. A spec is `path[:alias]`. A file
/// becomes the module named by its file name without the extension, or by
/// the alias. A directory contributes every `.lus` and `.lua` file below
/// it, named by its path from the directory's own name.
const Preincludes = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    list: std.ArrayList(package.Preinclude) = .empty,

    fn deinit(p: *Preincludes) void {
        for (p.list.items) |e| {
            p.gpa.free(e.name);
            p.gpa.free(e.path);
            p.gpa.free(e.src);
        }
        p.list.deinit(p.gpa);
    }

    /// The colon that starts an alias, skipping a Windows drive prefix.
    fn aliasColon(spec: []const u8) ?usize {
        const c = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return null;
        if (c == 1 and std.ascii.isAlphabetic(spec[0]) and spec.len > 2 and (spec[2] == '/' or spec[2] == '\\')) return null;
        return c;
    }

    fn add(p: *Preincludes, spec: []const u8) !void {
        const colon = aliasColon(spec);
        const path = if (colon) |c| spec[0..c] else spec;
        if (colon == null) {
            if (std.Io.Dir.cwd().statFile(p.io, path, .{})) |st| {
                if (st.kind == .directory) {
                    const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/\\"));
                    return p.addDir(path, base);
                }
            } else |_| {}
        }
        const name = if (colon) |c| try p.gpa.dupe(u8, spec[c + 1 ..]) else try moduleName(p.gpa, std.fs.path.basename(path), "");
        try p.addFile(path, name);
    }

    fn moduleName(gpa: std.mem.Allocator, file: []const u8, prefix: []const u8) ![]u8 {
        var stem = file;
        if (std.mem.endsWith(u8, stem, ".lus") or std.mem.endsWith(u8, stem, ".lua")) stem = stem[0 .. stem.len - 4];
        if (prefix.len == 0) return gpa.dupe(u8, stem);
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, stem });
    }

    /// Takes ownership of `name`.
    fn addFile(p: *Preincludes, path: []const u8, name: []u8) !void {
        errdefer p.gpa.free(name);
        for (p.list.items) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                std.debug.print("lus: duplicate preincluded module '{s}' ({s})\n", .{ name, path });
                return error.Reported;
            }
        }
        const src = std.Io.Dir.cwd().readFileAlloc(p.io, path, p.gpa, .unlimited) catch {
            std.debug.print("lus: cannot read include file '{s}'\n", .{path});
            return error.Reported;
        };
        errdefer p.gpa.free(src);
        const owned_path = try p.gpa.dupe(u8, path);
        errdefer p.gpa.free(owned_path);
        try p.list.append(p.gpa, .{ .name = name, .path = owned_path, .src = src });
    }

    fn addDir(p: *Preincludes, path: []const u8, prefix: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(p.io, path, .{ .iterate = true }) catch {
            std.debug.print("lus: failed to include directory '{s}'\n", .{path});
            return error.Reported;
        };
        defer dir.close(p.io);
        var it = dir.iterate();
        while (it.next(p.io) catch {
            std.debug.print("lus: failed to include directory '{s}'\n", .{path});
            return error.Reported;
        }) |ent| {
            if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
            const full = try std.fmt.allocPrint(p.gpa, "{s}/{s}", .{ path, ent.name });
            defer p.gpa.free(full);
            if (ent.kind == .directory) {
                const sub = try std.fmt.allocPrint(p.gpa, "{s}.{s}", .{ prefix, ent.name });
                defer p.gpa.free(sub);
                try p.addDir(full, sub);
            } else if (std.mem.endsWith(u8, ent.name, ".lus") or std.mem.endsWith(u8, ent.name, ".lua")) {
                try p.addFile(full, try moduleName(p.gpa, ent.name, prefix));
            }
        }
    }
};

fn setArgTable(l: *Thread, args: []const []const u8, script_index: usize, has_script: bool) !void {
    // The table becomes the global first, so it stays reachable while
    // the strings it receives are allocated.
    const t = try l.newTable(args.len, 2);
    try lus.lib.aux.setGlobal(l, "arg", Value.obj(.table, t));
    const base: i64 = if (has_script) @intCast(script_index) else @intCast(args.len);
    for (args, 0..) |a, i| {
        const v = try l.newStringValue(a);
        try lus.vm.ops.rawSet(l, t, Value.int(@as(i64, @intCast(i)) - base), v);
    }
}

fn reportError(l: *Thread) void {
    const msg = api.errorMessage(l, l.err);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(l.g.gpa);
    buf.print(l.g.gpa, "lus: {s}\n", .{msg}) catch return;
    if (l.err_traceback) |tb| buf.print(l.g.gpa, "{s}\n", .{tb.bytes()}) catch {};
    out.stderr(l.g, buf.items);
}

fn runString(l: *Thread, src: []const u8, name: []const u8) bool {
    return runChunk(l, src, name, &.{});
}

fn runChunk(l: *Thread, src: []const u8, name: []const u8, script_args: []const []const u8) bool {
    const base = l.top;
    api.load(l, src, name) catch {
        reportError(l);
        l.top = base;
        return false;
    };
    for (script_args) |a| {
        const v = l.newStringValue(a) catch return false;
        l.push(v) catch return false;
    }
    l.want_traceback = true;
    l.err_traceback = null;
    defer l.want_traceback = false;
    if (!api.pcall(l, @intCast(script_args.len), 0)) {
        reportError(l);
        l.top = base;
        return false;
    }
    l.top = base;
    // The chunk is done. The coroutines it detached run to their end.
    l.err_traceback = null;
    if (!api.runPending(l, true)) {
        reportError(l);
        return false;
    }
    return true;
}

/// Prints the bytecode of a script compiled exactly as running it would
/// compile it, with the same chunk name and compile-time flags.
fn disassemble(l: *Thread, path: []const u8) !u8 {
    const gpa = l.g.gpa;
    const s = std.Io.Dir.cwd().readFileAlloc(l.g.io, path, gpa, .unlimited) catch |e| {
        std.debug.print("lus: cannot open {s} ({s})\n", .{ path, @errorName(e) });
        return 1;
    };
    defer gpa.free(s);
    const chunkname = try std.fmt.allocPrint(gpa, "@{s}", .{path});
    defer gpa.free(chunkname);
    const r = try lus.compile.codegen.compile(l.g, s, .{ .chunkname = chunkname, .flags = api.flagsTable(l.g) });
    switch (r) {
        .err => |m| {
            std.debug.print("{s}\n", .{m});
            gpa.free(m);
            return 1;
        },
        .ok => |p| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(gpa);
            try lus.compile.disasm.dump(gpa, &buf, p, 0);
            out.stdout(l.g).write(l.g, buf.items);
            return 0;
        },
    }
}

/// A minimal interactive loop: expressions print their values, and
/// statements run as typed. Incomplete input continues on the next line.
fn repl(l: *Thread, io: std.Io) !void {
    const gpa = l.g.gpa;
    std.debug.print("{s}\n", .{version});
    var rbuf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    while (true) {
        out.stderr(l.g, if (pending.items.len == 0) "> " else ">> ");
        const line = r.interface.takeDelimiterExclusive('\n') catch break;
        r.interface.toss(1);
        if (pending.items.len > 0) try pending.append(gpa, '\n');
        try pending.appendSlice(gpa, line);
        // Try as an expression first.
        const expr_src = try std.fmt.allocPrint(gpa, "return {s}", .{pending.items});
        defer gpa.free(expr_src);
        const base = l.top;
        api.load(l, expr_src, "=stdin") catch {
            l.top = base;
            api.load(l, pending.items, "=stdin") catch {
                const msg = api.errorMessage(l, l.err);
                l.top = base;
                if (std.mem.endsWith(u8, msg, "<eof>")) continue; // incomplete
                out.stderr(l.g, msg);
                out.stderr(l.g, "\n");
                pending.clearRetainingCapacity();
                continue;
            };
        };
        pending.clearRetainingCapacity();
        if (!api.pcall(l, 0, -1)) {
            reportError(l);
        } else if (!api.runPending(l, true)) {
            reportError(l);
        } else if (l.top > base) {
            const prn = try lus.lib.aux.getField(l, l.g.globals.as(lus.vm.object.Table), "print");
            var vals: std.ArrayList(Value) = .empty;
            defer vals.deinit(gpa);
            for (l.stack[base..l.top]) |v| try vals.append(gpa, v);
            l.top = base;
            _ = lus.vm.ops.callN(l, prn, vals.items, 0) catch reportError(l);
        }
        l.top = base;
        out.flushAll(l.g);
    }
}

/// True when the -P grants mention the file system, which makes them the
/// ceiling for reading the entry script.
/// Indexes the require tree of the main chunk before it runs
/// (`modtree.zig`). The index reads files under the authority of the
/// runtime, except those that the `-P` grants of the command line could
/// never allow. A failure to index leaves every module to `require`.
fn indexTree(l: *lus.vm.state.Thread, src: []const u8, chunkname: []const u8, cli: *const Cli) ?*lus.modtree.Index {
    const Ceiling = struct {
        fn mayRead(ctx: *anyopaque, path: []const u8) bool {
            const t: *lus.vm.state.Thread = @ptrCast(@alignCast(ctx));
            return pledge.allowed(t, "fs:read", path);
        }
        fn mayFetch(ctx: *anyopaque, url: []const u8) bool {
            const t: *lus.vm.state.Thread = @ptrCast(@alignCast(ctx));
            return pledge.allowed(t, "network:http", url);
        }
    };
    const path = blk: {
        if (!cli.ignore_env) if (l.g.environ) |e| if (e.get("LUS_PATH")) |p| break :blk p;
        break :blk package.default_path;
    };
    const ix = lus.modtree.build(l, src, chunkname, .{
        .path = path,
        .may_read = if (limitsFileReads(cli.pledges.items)) Ceiling.mayRead else null,
        .may_fetch = if (cli.no_prefetch) null else if (limitsGrants(cli.pledges.items)) Ceiling.mayFetch else Always.yes,
        .ctx = l,
        .skip = package.answeredEarly,
    }) catch return null;
    lus.modtree.current = ix;
    return ix;
}

fn dropIndex(gpa: std.mem.Allocator, ix: *lus.modtree.Index) void {
    lus.modtree.current = null;
    ix.deinit();
    gpa.destroy(ix);
}

const Always = struct {
    fn yes(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

/// Whether `-P` limits what the script may pledge. The script may then
/// pledge only within the grants of the command line.
fn limitsGrants(specs: []const []const u8) bool {
    return specs.len > 0;
}

fn limitsFileReads(specs: []const []const u8) bool {
    for (specs) |spec| {
        if (std.mem.startsWith(u8, spec, "fs") and (spec.len == 2 or spec[2] == ':' or spec[2] == '=')) return true;
    }
    return false;
}
