const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

pub usingnamespace std.os.windows;

pub const FILE_GENERIC_READ =
    windows.STANDARD_RIGHTS_READ |
    windows.FILE_READ_DATA |
    windows.FILE_READ_ATTRIBUTES |
    windows.FILE_READ_EA |
    windows.SYNCHRONIZE;
pub const FILE_GENERIC_WRITE =
    windows.STANDARD_RIGHTS_WRITE |
    windows.FILE_WRITE_DATA |
    windows.FILE_WRITE_ATTRIBUTES |
    windows.FILE_WRITE_EA |
    windows.SYNCHRONIZE;

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

pub fn ReadFileW(
    handle: windows.HANDLE,
    buffer: []u8,
    overlapped: ?*windows.OVERLAPPED,
) windows.ReadFileError!?usize {
    var read: windows.DWORD = 0;
    const result: windows.BOOL = kernel32.ReadFile(handle, buffer.ptr, @intCast(windows.DWORD, buffer.len), &read, overlapped);
    if (result == windows.FALSE) {
        const err = kernel32.GetLastError();
        return switch (err) {
            windows.Win32Error.IO_PENDING => null,
            else => windows.unexpectedError(err),
        };
    }

    return @intCast(usize, read);
}

pub fn WriteFileW(
    handle: windows.HANDLE,
    buffer: []const u8,
    overlapped: ?*windows.OVERLAPPED,
) windows.WriteFileError!?usize {
    var written: windows.DWORD = 0;
    const result: windows.BOOL = kernel32.WriteFile(handle, buffer.ptr, @intCast(windows.DWORD, buffer.len), &written, overlapped);
    if (result == windows.FALSE) {
        const err = kernel32.GetLastError();
        return switch (err) {
            windows.Win32Error.IO_PENDING => null,
            else => windows.unexpectedError(err),
        };
    }

    return @intCast(usize, written);
}

pub const DeleteFileError = error{} || std.os.UnexpectedError;

pub fn DeleteFileW(name: [*:0]const u16) DeleteFileError!void {
    const result: windows.BOOL = kernel32.DeleteFileW(name);
    if (result == windows.FALSE) {
        const err = kernel32.GetLastError();
        return switch (err) {
            else => windows.unexpectedError(err),
        };
    }
}
