//! Running a command through the system shell, for `io.popen` and
//! `os.execute`. POSIX systems run `/bin/sh -c command`. Windows runs
//! `cmd.exe /s /c "command"`, which hands `cmd.exe` the command exactly as
//! written, so quoting, redirection, and pipes follow the rules of
//! `cmd.exe`.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

/// Which standard stream of the child the parent holds a pipe to. The
/// other streams are inherited.
pub const Pipe = enum { none, stdin, stdout };

pub const SpawnError = std.process.SpawnError || std.mem.Allocator.Error;

/// Starts `command` in the system shell. The caller waits for the child
/// with `std.process.Child.wait`. The child gets the environment `env`, or
/// the environment of the process when it is null.
pub fn spawn(io: std.Io, gpa: std.mem.Allocator, command: []const u8, pipe: Pipe, env: ?*const std.process.Environ.Map) SpawnError!std.process.Child {
    if (comptime windows) return spawnWindows(gpa, command, pipe, env);
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = if (pipe == .stdin) .pipe else .inherit,
        .stdout = if (pipe == .stdout) .pipe else .inherit,
        .environ_map = env,
    });
}

/// The command line `cmd.exe /s /c "command"`. With `/s`, `cmd.exe` removes
/// the first and the last quote of the text after `/c` and runs the rest,
/// so the surrounding quotes give back the command unchanged whatever
/// quotes it holds. Arguments built by the standard library spawner are
/// quoted for `CommandLineToArgvW`, which `cmd.exe` does not use, so the
/// command line is assembled here.
pub fn windowsCommandLine(gpa: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "cmd.exe /s /c \"", command, "\"" });
}

/// How a child ended. An exit code keeps all its bits, which on Windows
/// are 32, so a code such as 256 or an NTSTATUS crash code never reads as
/// success.
pub const Status = union(enum) {
    exited: u32,
    signal: u32,

    pub fn success(s: Status) bool {
        return s == .exited and s.exited == 0;
    }
};

/// Waits for `child` and reports how it ended. The standard library keeps
/// only the low byte of a Windows exit code, so on Windows the full code
/// is read with GetExitCodeProcess before the wait closes the handles.
pub fn wait(io: std.Io, child: *std.process.Child) std.process.Child.WaitError!Status {
    const full: ?u32 = if (comptime windows) win.exitCode(child.id.?) else null;
    const term = try child.wait(io);
    if (full) |code| return .{ .exited = code };
    return switch (term) {
        .exited => |code| .{ .exited = code },
        // WASI has no signals, so its signal payload is void.
        .signal, .stopped => |sig| .{ .signal = if (@TypeOf(sig) == void) 0 else @intCast(@backingInt(sig)) },
        .unknown => |code| .{ .exited = code },
    };
}

const win = if (windows) struct {
    const w = std.os.windows;
    const HANDLE_FLAG_INHERIT: w.DWORD = 0x1;
    const DUPLICATE_SAME_ACCESS: w.DWORD = 0x2;
    const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x20002;
    const INFINITE: u32 = 0xFFFFFFFF;
    const STARTUPINFOEXW = extern struct {
        info: w.STARTUPINFOW,
        attribute_list: ?*anyopaque,
    };
    extern "kernel32" fn CreatePipe(read: *w.HANDLE, write: *w.HANDLE, attributes: ?*const w.SECURITY_ATTRIBUTES, size: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetHandleInformation(object: w.HANDLE, mask: w.DWORD, flags: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DuplicateHandle(source_process: w.HANDLE, source: w.HANDLE, target_process: w.HANDLE, target: *w.HANDLE, access: w.DWORD, inherit: w.BOOL, options: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: w.DWORD, flags: w.DWORD, size: *usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: w.DWORD, attribute: usize, value: *const anyopaque, size: usize, previous: ?*anyopaque, return_size: ?*usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetExitCodeProcess(process: w.HANDLE, code: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, ms: u32) callconv(.winapi) u32;

    /// The exit code of a process, once it has ended.
    fn exitCode(process: w.HANDLE) ?u32 {
        _ = WaitForSingleObject(process, INFINITE);
        var code: w.DWORD = 0;
        if (!GetExitCodeProcess(process, &code).toBool()) return null;
        return code;
    }

    /// An inheritable duplicate of `h`, or null for a missing handle or
    /// when it cannot be duplicated.
    fn inheritable(h: ?w.HANDLE) ?w.HANDLE {
        const src = h orelse return null;
        if (src == w.INVALID_HANDLE_VALUE) return null;
        var dup: w.HANDLE = undefined;
        const self = w.GetCurrentProcess();
        if (!DuplicateHandle(self, src, self, &dup, 0, .TRUE, DUPLICATE_SAME_ACCESS).toBool()) return null;
        return dup;
    }
} else struct {};

fn spawnWindows(gpa: std.mem.Allocator, command: []const u8, pipe: Pipe, env: ?*const std.process.Environ.Map) SpawnError!std.process.Child {
    const w = std.os.windows;
    const line = try windowsCommandLine(gpa, command);
    defer gpa.free(line);
    const line_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWtf8,
    };
    defer gpa.free(line_w);
    // The shell is the cmd.exe of the system directory, so a file of that
    // name in the working directory is never run in its place.
    const sys = std.mem.trimEnd(u16, w.getSystemDirectoryWtf16Le(), &.{ '/', '\\' });
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\cmd.exe");
    const app = try gpa.allocSentinel(u16, sys.len + suffix.len, 0);
    defer gpa.free(app);
    @memcpy(app[0..sys.len], sys);
    @memcpy(app[sys.len..], suffix);

    // Both ends of the pipe start without the inherit flag. The child
    // inherits exactly its three standard handles through a handle list,
    // so it never picks up a handle that another thread made inheritable
    // for a child of its own. Every handle in the list is an inheritable
    // duplicate that lives only until CreateProcessW returns.
    var ends: [2]w.HANDLE = undefined;
    if (pipe != .none) {
        if (!win.CreatePipe(&ends[0], &ends[1], null, 0).toBool()) return error.SystemResources;
    }
    const parent_end: ?w.HANDLE = switch (pipe) {
        .none => null,
        .stdin => ends[1],
        .stdout => ends[0],
    };
    const child_end: ?w.HANDLE = switch (pipe) {
        .none => null,
        .stdin => ends[0],
        .stdout => ends[1],
    };
    // The parent closes its copy of the child end once the child has
    // been created, or on failure, and keeps the parent end on success.
    defer if (child_end) |h| w.CloseHandle(h);
    errdefer if (parent_end) |h| w.CloseHandle(h);

    const params = w.peb().ProcessParameters;
    const std_in = win.inheritable(if (pipe == .stdin) child_end else params.hStdInput);
    defer if (std_in) |h| w.CloseHandle(h);
    const std_out = win.inheritable(if (pipe == .stdout) child_end else params.hStdOutput);
    defer if (std_out) |h| w.CloseHandle(h);
    const std_err = win.inheritable(params.hStdError);
    defer if (std_err) |h| w.CloseHandle(h);
    // The pipe end the child needs must reach it.
    if (pipe == .stdin and std_in == null) return error.SystemResources;
    if (pipe == .stdout and std_out == null) return error.SystemResources;

    var list: [3]w.HANDLE = undefined;
    var count: usize = 0;
    for ([_]?w.HANDLE{ std_in, std_out, std_err }) |h| {
        if (h) |v| {
            list[count] = v;
            count += 1;
        }
    }
    var attr_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_mem = try gpa.alignedAlloc(u8, .of(usize), @max(attr_size, 1));
    defer gpa.free(attr_mem);
    const attrs: *anyopaque = attr_mem.ptr;
    if (!win.InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size).toBool()) return error.SystemResources;
    defer win.DeleteProcThreadAttributeList(attrs);
    if (count > 0 and !win.UpdateProcThreadAttribute(attrs, 0, win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &list, count * @sizeOf(w.HANDLE), null, null).toBool())
        return error.SystemResources;

    var si: win.STARTUPINFOEXW = .{
        .info = .{
            .cb = @sizeOf(win.STARTUPINFOEXW),
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .dwFlags = w.STARTF_USESTDHANDLES,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
            .hStdInput = std_in,
            .hStdOutput = std_out,
            .hStdError = std_err,
        },
        .attribute_list = attrs,
    };
    var pi: w.PROCESS.INFORMATION = undefined;
    // With a handle list, bInheritHandles lets the child inherit only the
    // handles of the list.
    const inherit: w.BOOL = if (count > 0) .TRUE else .FALSE;
    const block: ?std.process.Environ.WindowsBlock = if (env) |m| m.createWindowsBlock(gpa, .{ .zig_progress_handle = null }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidWtf8,
    } else null;
    defer if (block) |b| b.deinit(gpa);
    const env_ptr: ?[*:0]const u16 = if (block) |b| b.slice.ptr else null;
    if (!w.kernel32.CreateProcessW(app.ptr, line_w.ptr, null, null, inherit, .{ .extended_startupinfo_present = true, .create_unicode_environment = block != null }, env_ptr, null, &si.info, &pi).toBool()) {
        return switch (w.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .FILENAME_EXCED_RANGE => error.NameTooLong,
            else => error.Unexpected,
        };
    }
    return .{
        .id = pi.hProcess,
        .thread_handle = pi.hThread,
        .stdin = if (pipe == .stdin) .{ .handle = parent_end.?, .flags = .{ .nonblocking = false } } else null,
        .stdout = if (pipe == .stdout) .{ .handle = parent_end.?, .flags = .{ .nonblocking = false } } else null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

test "windows command line" {
    const gpa = std.testing.allocator;
    const line = try windowsCommandLine(gpa, "\"C:\\a b\\lus.exe\" -v 2>&1");
    defer gpa.free(line);
    try std.testing.expectEqualStrings("cmd.exe /s /c \"\"C:\\a b\\lus.exe\" -v 2>&1\"", line);
}
