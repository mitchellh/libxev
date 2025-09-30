//! Namespace containing missing utils from std

const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;

// Forwarded declarations of std.os.windows.
pub const DWORD = windows.DWORD;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;
pub const INFINITE = windows.INFINITE;
pub const HANDLE = windows.HANDLE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const OVERLAPPED = windows.OVERLAPPED;
pub const OVERLAPPED_ENTRY = windows.OVERLAPPED_ENTRY;
pub const DUPLICATE_SAME_ACCESS = windows.DUPLICATE_SAME_ACCESS;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const GENERIC_WRITE = windows.GENERIC_WRITE;
pub const OPEN_ALWAYS = windows.OPEN_ALWAYS;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const ReadFileError = windows.ReadFileError;
pub const WriteFileError = windows.WriteFileError;
pub const Win32Error = windows.Win32Error;
pub const WSASocketW = windows.WSASocketW;
pub const kernel32 = windows.kernel32;
pub const ws2_32 = windows.ws2_32;
pub const unexpectedWSAError = windows.unexpectedWSAError;
pub const unexpectedError = windows.unexpectedError;
pub const sliceToPrefixedFileW = windows.sliceToPrefixedFileW;
pub const CloseHandle = windows.CloseHandle;
pub const QueryPerformanceCounter = windows.QueryPerformanceCounter;
pub const QueryPerformanceFrequency = windows.QueryPerformanceFrequency;
pub const GetQueuedCompletionStatusEx = windows.GetQueuedCompletionStatusEx;
pub const PostQueuedCompletionStatus = windows.PostQueuedCompletionStatus;
pub const CreateIoCompletionPort = windows.CreateIoCompletionPort;

pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) windows.BOOL;

pub const exp = struct {
    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const JOBOBJECT_ASSOCIATE_COMPLETION_PORT = extern struct {
        CompletionKey: windows.ULONG_PTR,
        CompletionPort: windows.HANDLE,
    };

    pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: windows.LARGE_INTEGER,
        PerJobUserTimeLimit: windows.LARGE_INTEGER,
        LimitFlags: windows.DWORD,
        MinimumWorkingSetSize: windows.SIZE_T,
        MaximumWorkingSetSize: windows.SIZE_T,
        ActiveProcessLimit: windows.DWORD,
        Affinity: windows.ULONG_PTR,
        PriorityClass: windows.DWORD,
        SchedulingClass: windows.DWORD,
    };

    pub const IO_COUNTERS = extern struct {
        ReadOperationCount: windows.ULONGLONG,
        WriteOperationCount: windows.ULONGLONG,
        OtherOperationCount: windows.ULONGLONG,
        ReadTransferCount: windows.ULONGLONG,
        WriteTransferCount: windows.ULONGLONG,
        OtherTransferCount: windows.ULONGLONG,
    };

    pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: windows.SIZE_T,
        JobMemoryLimit: windows.SIZE_T,
        PeakProcessMemoryUsed: windows.SIZE_T,
        PeakJobMemoryUsed: windows.SIZE_T,
    };

    pub const JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008;
    pub const JOB_OBJECT_LIMIT_AFFINITY = 0x00000010;
    pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
    pub const JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x00000400;
    pub const JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200;
    pub const JOB_OBJECT_LIMIT_JOB_TIME = 0x00000004;
    pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    pub const JOB_OBJECT_LIMIT_PRESERVE_JOB_TIME = 0x00000004;
    pub const JOB_OBJECT_LIMIT_PRIORITY_CLASS = 0x00000020;
    pub const JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x00000100;
    pub const JOB_OBJECT_LIMIT_PROCESS_TIME = 0x00000002;
    pub const JOB_OBJECT_LIMIT_SCHEDULING_CLASS = 0x00000080;
    pub const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
    pub const JOB_OBJECT_LIMIT_SUBSET_AFFINITY = 0x00004000;
    pub const JOB_OBJECT_LIMIT_WORKINGSET = 0x00000001;

    pub const JOBOBJECT_INFORMATION_CLASS = enum(c_int) {
        JobObjectAssociateCompletionPortInformation = 7,
        JobObjectBasicLimitInformation = 2,
        JobObjectBasicUIRestrictions = 4,
        JobObjectCpuRateControlInformation = 15,
        JobObjectEndOfJobTimeInformation = 6,
        JobObjectExtendedLimitInformation = 9,
        JobObjectGroupInformation = 11,
        JobObjectGroupInformationEx = 14,
        JobObjectLimitViolationInformation2 = 34,
        JobObjectNetRateControlInformation = 32,
        JobObjectNotificationLimitInformation = 12,
        JobObjectNotificationLimitInformation2 = 33,
        JobObjectSecurityLimitInformation = 5,
    };

    pub const JOB_OBJECT_MSG_TYPE = enum(windows.DWORD) {
        JOB_OBJECT_MSG_END_OF_JOB_TIME = 1,
        JOB_OBJECT_MSG_END_OF_PROCESS_TIME = 2,
        JOB_OBJECT_MSG_ACTIVE_PROCESS_LIMIT = 3,
        JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO = 4,
        JOB_OBJECT_MSG_NEW_PROCESS = 6,
        JOB_OBJECT_MSG_EXIT_PROCESS = 7,
        JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS = 8,
        JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT = 9,
        JOB_OBJECT_MSG_JOB_MEMORY_LIMIT = 10,
        JOB_OBJECT_MSG_NOTIFICATION_LIMIT = 11,
        JOB_OBJECT_MSG_JOB_CYCLE_TIME_LIMIT = 12,
        JOB_OBJECT_MSG_SILO_TERMINATED = 13,
        _,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn GetProcessId(Process: windows.HANDLE) callconv(.winapi) windows.DWORD;
        pub extern "kernel32" fn CreateJobObjectA(lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES, lpName: ?windows.LPCSTR) callconv(.winapi) windows.HANDLE;
        pub extern "kernel32" fn AssignProcessToJobObject(hJob: windows.HANDLE, hProcess: windows.HANDLE) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetInformationJobObject(
            hJob: windows.HANDLE,
            JobObjectInformationClass: JOBOBJECT_INFORMATION_CLASS,
            lpJobObjectInformation: windows.LPVOID,
            cbJobObjectInformationLength: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    };

    pub const CreateFileError = error{} || posix.UnexpectedError;

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

    pub const DeleteFileError = error{} || posix.UnexpectedError;

    pub fn DeleteFile(name: [*:0]const u16) DeleteFileError!void {
        const result: windows.BOOL = DeleteFileW(name);
        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                else => windows.unexpectedError(err),
            };
        }
    }

    pub const CreateJobObjectError = error{AlreadyExists} || posix.UnexpectedError;
    pub fn CreateJobObject(
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
        lpName: ?windows.LPCSTR,
    ) !windows.HANDLE {
        const handle = exp.kernel32.CreateJobObjectA(lpSecurityAttributes, lpName);
        return switch (windows.kernel32.GetLastError()) {
            .SUCCESS => handle,
            .ALREADY_EXISTS => CreateJobObjectError.AlreadyExists,
            else => |err| windows.unexpectedError(err),
        };
    }

    pub fn AssignProcessToJobObject(hJob: windows.HANDLE, hProcess: windows.HANDLE) posix.UnexpectedError!void {
        const result: windows.BOOL = exp.kernel32.AssignProcessToJobObject(hJob, hProcess);
        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                else => windows.unexpectedError(err),
            };
        }
    }

    pub fn SetInformationJobObject(
        hJob: windows.HANDLE,
        JobObjectInformationClass: JOBOBJECT_INFORMATION_CLASS,
        lpJobObjectInformation: windows.LPVOID,
        cbJobObjectInformationLength: windows.DWORD,
    ) posix.UnexpectedError!void {
        const result: windows.BOOL = exp.kernel32.SetInformationJobObject(
            hJob,
            JobObjectInformationClass,
            lpJobObjectInformation,
            cbJobObjectInformationLength,
        );

        if (result == windows.FALSE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                else => windows.unexpectedError(err),
            };
        }
    }
};
