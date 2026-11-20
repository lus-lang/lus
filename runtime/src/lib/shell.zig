//! Running a command through the system shell, for `io.popen` and
//! `os.execute`. POSIX systems run `/bin/sh -c command`. Windows runs
//! `cmd.exe /c command` with the command appended to the command line
//! verbatim, as the C library's `_popen` and `system` do, so quoting,
//! redirection, and pipes follow the rules of `cmd.exe`.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

/// Which standard stream of the child the parent holds a pipe to. The
/// other streams are inherited.
pub const Pipe = enum { none, stdin, stdout };

pub const SpawnError = std.process.SpawnError || std.mem.Allocator.Error;

/// Starts `command` in the system shell. The caller waits for the child
/// with `std.process.Child.wait`.
pub fn spawn(io: std.Io, gpa: std.mem.Allocator, command: []const u8, pipe: Pipe) SpawnError!std.process.Child {
    if (comptime windows) return spawnWindows(gpa, command, pipe);
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = if (pipe == .stdin) .pipe else .inherit,
        .stdout = if (pipe == .stdout) .pipe else .inherit,
    });
}

/// The command line `cmd.exe /c command`. Arguments built by the standard
/// library spawner are quoted for `CommandLineToArgvW`, which `cmd.exe`
/// does not use, so the command line is assembled here.
pub fn windowsCommandLine(gpa: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ "cmd.exe /c ", command });
}

const win = if (windows) struct {
    const w = std.os.windows;
    const HANDLE_FLAG_INHERIT: w.DWORD = 0x1;
    extern "kernel32" fn CreatePipe(read: *w.HANDLE, write: *w.HANDLE, attributes: ?*const w.SECURITY_ATTRIBUTES, size: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetHandleInformation(object: w.HANDLE, mask: w.DWORD, flags: w.DWORD) callconv(.winapi) w.BOOL;
} else struct {};

fn spawnWindows(gpa: std.mem.Allocator, command: []const u8, pipe: Pipe) SpawnError!std.process.Child {
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

    // The child end of the pipe is inheritable and the parent end is not.
    var ends: [2]w.HANDLE = undefined;
    if (pipe != .none) {
        const sa: w.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
        if (!win.CreatePipe(&ends[0], &ends[1], &sa, 0).toBool()) return error.SystemResources;
        const parent_end = if (pipe == .stdout) ends[0] else ends[1];
        if (!win.SetHandleInformation(parent_end, win.HANDLE_FLAG_INHERIT, 0).toBool()) {
            w.CloseHandle(ends[0]);
            w.CloseHandle(ends[1]);
            return error.SystemResources;
        }
    }
    const params = w.peb().ProcessParameters;
    var si: w.STARTUPINFOW = .{
        .cb = @sizeOf(w.STARTUPINFOW),
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
        .hStdInput = if (pipe == .stdin) ends[0] else params.hStdInput,
        .hStdOutput = if (pipe == .stdout) ends[1] else params.hStdOutput,
        .hStdError = params.hStdError,
    };
    var pi: w.PROCESS.INFORMATION = undefined;
    const ok = w.kernel32.CreateProcessW(app.ptr, line_w.ptr, null, null, .TRUE, .{}, null, null, &si, &pi).toBool();
    const err = if (ok) w.Win32Error.SUCCESS else w.GetLastError();
    // The child holds its own copy of its end.
    if (pipe == .stdout) w.CloseHandle(ends[1]);
    if (pipe == .stdin) w.CloseHandle(ends[0]);
    if (!ok) {
        if (pipe == .stdout) w.CloseHandle(ends[0]);
        if (pipe == .stdin) w.CloseHandle(ends[1]);
        return switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .FILENAME_EXCED_RANGE => error.NameTooLong,
            else => error.Unexpected,
        };
    }
    return .{
        .id = pi.hProcess,
        .thread_handle = pi.hThread,
        .stdin = if (pipe == .stdin) .{ .handle = ends[1], .flags = .{ .nonblocking = false } } else null,
        .stdout = if (pipe == .stdout) .{ .handle = ends[0], .flags = .{ .nonblocking = false } } else null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

test "windows command line" {
    const gpa = std.testing.allocator;
    const line = try windowsCommandLine(gpa, "\"C:\\a b\\lus.exe\" -v 2>&1");
    defer gpa.free(line);
    try std.testing.expectEqualStrings("cmd.exe /c \"C:\\a b\\lus.exe\" -v 2>&1", line);
}
