const std = @import("std");
const windows = std.os.windows;

pub usingnamespace std.os.windows;

/// Namespace containing missing utils from std
pub const exp = struct {
    pub const CreateFileError = error{} || std.os.UnexpectedError;

    pub fn CreateFile(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: windows.DWORD,
        dwShareMode: windows.DWORD,
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: windows.DWORD,
        dwFlagsAndAttributes: windows.DWORD,
        hTemplateFile: ?windows.HANDLE,
    ) CreateFileError!windows.HANDLE {
        const handle = windows.kernel32.CreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
        if (handle == windows.INVALID_HANDLE_VALUE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                else => windows.unexpectedError(err),
            };
        }

        return handle;
    }

    pub fn ReadFile(
        handle: windows.HANDLE,
        buffer: []u8,
        overlapped: ?*windows.OVERLAPPED,
    ) windows.ReadFileError!?usize {
        var read: windows.DWORD = 0;
        const result: windows.BOOL = windows.kernel32.ReadFile(handle, buffer.ptr, @as(windows.DWORD, @intCast(buffer.len)), &read, overlapped);
        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                windows.Win32Error.IO_PENDING => null,
                else => windows.unexpectedError(err),
            };
        }

        return @as(usize, @intCast(read));
    }

    pub fn WriteFile(
        handle: windows.HANDLE,
        buffer: []const u8,
        overlapped: ?*windows.OVERLAPPED,
    ) windows.WriteFileError!?usize {
        var written: windows.DWORD = 0;
        const result: windows.BOOL = windows.kernel32.WriteFile(handle, buffer.ptr, @as(windows.DWORD, @intCast(buffer.len)), &written, overlapped);
        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                windows.Win32Error.IO_PENDING => null,
                else => windows.unexpectedError(err),
            };
        }

        return @as(usize, @intCast(written));
    }

    pub const DeleteFileError = error{} || std.os.UnexpectedError;

    pub fn DeleteFile(name: [*:0]const u16) DeleteFileError!void {
        const result: windows.BOOL = windows.kernel32.DeleteFileW(name);
        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                else => windows.unexpectedError(err),
            };
        }
    }
};
