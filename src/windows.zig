//! Namespace containing missing utils from std.
//! This acts as a compat shim for Win32 APIs removed from std.os.windows in Zig 0.16.

const std = @import("std");
const win = std.os.windows;
const posix = std.posix;

// Forwarded declarations of std.os.windows types that still exist.
pub const ULONG_PTR = win.ULONG_PTR;
pub const PVOID = win.PVOID;
pub const DWORD = win.DWORD;
pub const HANDLE = win.HANDLE;
pub const INVALID_HANDLE_VALUE = win.INVALID_HANDLE_VALUE;
pub const Win32Error = win.Win32Error;
pub const DUPLICATE_SAME_ACCESS = win.DUPLICATE_SAME_ACCESS;
pub const unexpectedError = win.unexpectedError;
pub const CloseHandle = win.CloseHandle;

pub const BOOL = win.BOOL;
pub const FALSE: BOOL = .FALSE;
pub const TRUE: BOOL = BOOL.TRUE;

// Constants removed from std.os.windows in Zig 0.16.
pub const INFINITE: DWORD = 0xFFFF_FFFF;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR = 0,
    InternalHigh: ULONG_PTR = 0,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    } = .{ .DUMMYSTRUCTNAME = .{ .Offset = 0, .OffsetHigh = 0 } },
    hEvent: ?HANDLE = null,
};
pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
    Internal: ULONG_PTR,
    dwNumberOfBytesTransferred: DWORD,
};

pub const WSABUF = extern struct {
    len: win.ULONG,
    buf: [*]u8,
};

pub const ReadFileError = error{
    BrokenPipe,
    ConnectionResetByPeer,
    OperationAborted,
    LockViolation,
    AccessDenied,
    NotOpenForReading,
    Unexpected,
};
pub const WriteFileError = error{
    SystemResources,
    OperationAborted,
    BrokenPipe,
    NotOpenForWriting,
    LockViolation,
    ConnectionResetByPeer,
    AccessDenied,
    Unexpected,
};

// --- kernel32 compat shim ---
// In Zig 0.16, nearly all kernel32 extern functions were removed from std.
// We re-declare the ones this project needs.
pub const kernel32 = struct {
    pub fn GetLastError() Win32Error {
        return win.GetLastError();
    }

    pub fn GetCurrentProcess() HANDLE {
        return win.GetCurrentProcess();
    }

    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: *anyopaque,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WriteFile(
        in_hFile: HANDLE,
        in_lpBuffer: [*]const u8,
        in_nNumberOfBytesToWrite: DWORD,
        out_lpNumberOfBytesWritten: ?*DWORD,
        in_out_lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CancelIoEx(
        hFile: HANDLE,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn DuplicateHandle(
        hSourceProcessHandle: HANDLE,
        hSourceHandle: HANDLE,
        hTargetProcessHandle: HANDLE,
        lpTargetHandle: *HANDLE,
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwOptions: DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetExitCodeProcess(
        hProcess: HANDLE,
        lpExitCode: *DWORD,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: ULONG_PTR,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;

    pub extern "kernel32" fn GetQueuedCompletionStatusEx(
        CompletionPort: HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: win.ULONG,
        ulNumEntriesRemoved: *win.ULONG,
        dwMilliseconds: DWORD,
        fAlertable: BOOL,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn PostQueuedCompletionStatus(
        CompletionPort: HANDLE,
        dwNumberOfBytesTransferred: DWORD,
        dwCompletionKey: ULONG_PTR,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn DeleteFileW(
        lpFileName: [*:0]const u16,
    ) callconv(.winapi) BOOL;
};

// --- ws2_32 compat shim ---
// In Zig 0.16, all ws2_32 extern functions, WinsockError, WSABUF, WSA_FLAG_OVERLAPPED, etc.
// were removed. We re-declare the ones this project needs, and forward remaining constants.
pub const ws2_32 = struct {
    pub const SOCKET = *opaque {};
    pub const INVALID_SOCKET: SOCKET = @ptrFromInt(~@as(usize, 0));
    pub const SOCKET_ERROR: i32 = -1;
    pub const WSA_FLAG_OVERLAPPED: u32 = 1;

    pub const LPWSAOVERLAPPED_COMPLETION_ROUTINE = *const fn (
        dwError: DWORD,
        cbTransferred: DWORD,
        lpOverlapped: *OVERLAPPED,
        dwFlags: DWORD,
    ) callconv(.winapi) void;

    pub const WSAPROTOCOL_INFOW = extern struct {
        dwServiceFlags1: DWORD,
        dwServiceFlags2: DWORD,
        dwServiceFlags3: DWORD,
        dwServiceFlags4: DWORD,
        dwProviderFlags: DWORD,
        ProviderId: win.GUID,
        dwCatalogEntryId: DWORD,
        ProtocolChain: WSAPROTOCOLCHAIN,
        iVersion: c_int,
        iAddressFamily: c_int,
        iMaxSockAddr: c_int,
        iMinSockAddr: c_int,
        iSocketType: c_int,
        iProtocol: c_int,
        iProtocolMaxOffset: c_int,
        iNetworkByteOrder: c_int,
        iSecurityScheme: c_int,
        dwMessageSize: DWORD,
        dwProviderReserved: DWORD,
        szProtocol: [256]u16,
    };

    pub const WSAPROTOCOLCHAIN = extern struct {
        ChainLen: c_int,
        ChainEntries: [7]DWORD,
    };

    pub const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    pub const WinsockError = enum(u16) {
        WSA_INVALID_HANDLE = 6,
        WSA_NOT_ENOUGH_MEMORY = 8,
        WSA_INVALID_PARAMETER = 87,
        WSA_OPERATION_ABORTED = 995,
        WSA_IO_INCOMPLETE = 996,
        WSA_IO_PENDING = 997,
        WSAEINTR = 10004,
        WSAEBADF = 10009,
        WSAEACCES = 10013,
        WSAEFAULT = 10014,
        WSAEINVAL = 10022,
        WSAEMFILE = 10024,
        WSAEWOULDBLOCK = 10035,
        WSAEINPROGRESS = 10036,
        WSAEALREADY = 10037,
        WSAENOTSOCK = 10038,
        WSAEDESTADDRREQ = 10039,
        WSAEMSGSIZE = 10040,
        WSAEPROTOTYPE = 10041,
        WSAENOPROTOOPT = 10042,
        WSAEPROTONOSUPPORT = 10043,
        WSAESOCKTNOSUPPORT = 10044,
        WSAEOPNOTSUPP = 10045,
        WSAEPFNOSUPPORT = 10046,
        WSAEAFNOSUPPORT = 10047,
        WSAEADDRINUSE = 10048,
        WSAEADDRNOTAVAIL = 10049,
        WSAENETDOWN = 10050,
        WSAENETUNREACH = 10051,
        WSAENETRESET = 10052,
        WSAECONNABORTED = 10053,
        WSAECONNRESET = 10054,
        WSAENOBUFS = 10055,
        WSAEISCONN = 10056,
        WSAENOTCONN = 10057,
        WSAESHUTDOWN = 10058,
        WSAETOOMANYREFS = 10059,
        WSAETIMEDOUT = 10060,
        WSAECONNREFUSED = 10061,
        WSAELOOP = 10062,
        WSAENAMETOOLONG = 10063,
        WSAEHOSTDOWN = 10064,
        WSAEHOSTUNREACH = 10065,
        WSAENOTEMPTY = 10066,
        WSAEPROCLIM = 10067,
        WSAEUSERS = 10068,
        WSAEDQUOT = 10069,
        WSAESTALE = 10070,
        WSAEREMOTE = 10071,
        WSASYSNOTREADY = 10091,
        WSAVERNOTSUPPORTED = 10092,
        WSANOTINITIALISED = 10093,
        WSAEDISCON = 10101,
        WSAENOMORE = 10102,
        WSAECANCELLED = 10103,
        WSAEINVALIDPROCTABLE = 10104,
        WSAEINVALIDPROVIDER = 10105,
        WSAEPROVIDERFAILEDINIT = 10106,
        WSASYSCALLFAILURE = 10107,
        WSASERVICE_NOT_FOUND = 10108,
        WSATYPE_NOT_FOUND = 10109,
        WSA_E_NO_MORE = 10110,
        WSA_E_CANCELLED = 10111,
        WSAEREFUSED = 10112,
        WSAHOST_NOT_FOUND = 11001,
        WSATRY_AGAIN = 11002,
        WSANO_RECOVERY = 11003,
        WSANO_DATA = 11004,
        WSA_QOS_RECEIVERS = 11005,
        WSA_QOS_SENDERS = 11006,
        WSA_QOS_NO_SENDERS = 11007,
        WSA_QOS_NO_RECEIVERS = 11008,
        WSA_QOS_REQUEST_CONFIRMED = 11009,
        WSA_QOS_ADMISSION_FAILURE = 11010,
        WSA_QOS_POLICY_FAILURE = 11011,
        WSA_QOS_BAD_STYLE = 11012,
        WSA_QOS_BAD_OBJECT = 11013,
        WSA_QOS_TRAFFIC_CTRL_ERROR = 11014,
        WSA_QOS_GENERIC_ERROR = 11015,
        WSA_QOS_ESERVICETYPE = 11016,
        WSA_QOS_EFLOWSPEC = 11017,
        WSA_QOS_EPROVSPECBUF = 11018,
        WSA_QOS_EFILTERSTYLE = 11019,
        WSA_QOS_EFILTERTYPE = 11020,
        WSA_QOS_EFILTERCOUNT = 11021,
        WSA_QOS_EOBJLENGTH = 11022,
        WSA_QOS_EFLOWCOUNT = 11023,
        WSA_QOS_EUNKOWNPSOBJ = 11024,
        WSA_QOS_EPOLICYOBJ = 11025,
        WSA_QOS_EFLOWDESC = 11026,
        WSA_QOS_EPSFLOWSPEC = 11027,
        WSA_QOS_EPSFILTERSPEC = 11028,
        WSA_QOS_ESDMODEOBJ = 11029,
        WSA_QOS_ESHAPERATEOBJ = 11030,
        WSA_QOS_RESERVED_PETYPE = 11031,
        _,
    };

    // Forward constants/types from std that still exist.
    pub const sockaddr = win.ws2_32.sockaddr;
    pub const AF = win.ws2_32.AF;
    pub const SOCK = win.ws2_32.SOCK;
    pub const SOL = win.ws2_32.SOL;
    pub const SO = win.ws2_32.SO;
    pub const IPPROTO = win.ws2_32.IPPROTO;
    pub const SD_RECEIVE: i32 = 0;
    pub const SD_SEND: i32 = 1;
    pub const SD_BOTH: i32 = 2;

    pub extern "ws2_32" fn WSASocketW(
        af: i32,
        @"type": i32,
        protocol: i32,
        lpProtocolInfo: ?*WSAPROTOCOL_INFOW,
        g: u32,
        dwFlags: u32,
    ) callconv(.winapi) SOCKET;

    pub extern "ws2_32" fn WSAStartup(
        wVersionRequested: u16,
        lpWSAData: *WSADATA,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn connect(
        s: SOCKET,
        name: *const posix.sockaddr,
        namelen: i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn getsockname(
        s: SOCKET,
        name: *posix.sockaddr,
        namelen: *i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn getsockopt(
        s: SOCKET,
        level: i32,
        optname: i32,
        optval: [*]u8,
        optlen: *i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;

    pub extern "ws2_32" fn WSAGetOverlappedResult(
        s: SOCKET,
        lpOverlapped: *OVERLAPPED,
        lpcbTransfer: *u32,
        fWait: BOOL,
        lpdwFlags: *u32,
    ) callconv(.winapi) BOOL;

    pub extern "ws2_32" fn WSASend(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: u32,
        lpNumberOfBytesSent: ?*u32,
        dwFlags: u32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn WSARecv(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: u32,
        lpNumberOfBytesRecv: ?*u32,
        lpFlags: *u32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn WSASendTo(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: u32,
        lpNumberOfBytesSent: ?*u32,
        dwFlags: u32,
        lpTo: ?*const posix.sockaddr,
        iToLen: i32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn WSARecvFrom(
        s: SOCKET,
        lpBuffers: [*]WSABUF,
        dwBufferCount: u32,
        lpNumberOfBytesRecvd: ?*u32,
        lpFlags: *u32,
        lpFrom: ?*posix.sockaddr,
        lpFromlen: ?*i32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn shutdown(
        s: SOCKET,
        how: i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn closesocket(
        s: SOCKET,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn bind(
        s: SOCKET,
        name: *const posix.sockaddr,
        namelen: i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn listen(
        s: SOCKET,
        backlog: i32,
    ) callconv(.winapi) i32;

    pub extern "ws2_32" fn setsockopt(
        s: SOCKET,
        level: i32,
        optname: i32,
        optval: [*]const u8,
        optlen: i32,
    ) callconv(.winapi) i32;

    pub extern "mswsock" fn AcceptEx(
        sListenSocket: SOCKET,
        sAcceptSocket: SOCKET,
        lpOutputBuffer: *anyopaque,
        dwReceiveDataLength: u32,
        dwLocalAddressLength: u32,
        dwRemoteAddressLength: u32,
        lpdwBytesReceived: *u32,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;
};

// --- High-level wrapper functions ---

pub fn unexpectedWSAError(err: ws2_32.WinsockError) error{Unexpected} {
    return unexpectedError(@as(Win32Error, @enumFromInt(@intFromEnum(err))));
}

pub fn QueryPerformanceCounter() u64 {
    var result: win.LARGE_INTEGER = undefined;
    std.debug.assert(win.ntdll.RtlQueryPerformanceCounter(&result) != .FALSE);
    return @as(u64, @bitCast(result));
}

pub fn QueryPerformanceFrequency() u64 {
    var result: win.LARGE_INTEGER = undefined;
    std.debug.assert(win.ntdll.RtlQueryPerformanceFrequency(&result) != .FALSE);
    return @as(u64, @bitCast(result));
}

pub const GetQueuedCompletionStatusError = error{
    Aborted,
    Cancelled,
    EOF,
    Timeout,
} || error{Unexpected};

pub fn GetQueuedCompletionStatusEx(
    completion_port: HANDLE,
    completion_port_entries: []OVERLAPPED_ENTRY,
    timeout_ms: ?DWORD,
    alertable: bool,
) GetQueuedCompletionStatusError!u32 {
    var num_entries_removed: u32 = 0;

    const success = kernel32.GetQueuedCompletionStatusEx(
        completion_port,
        completion_port_entries.ptr,
        @as(win.ULONG, @intCast(completion_port_entries.len)),
        &num_entries_removed,
        timeout_ms orelse INFINITE,
        BOOL.fromBool(alertable),
    );

    if (success == .FALSE) {
        return switch (kernel32.GetLastError()) {
            .ABANDONED_WAIT_0 => error.Aborted,
            .OPERATION_ABORTED => error.Cancelled,
            .HANDLE_EOF => error.EOF,
            .WAIT_TIMEOUT => error.Timeout,
            else => |err| unexpectedError(err),
        };
    }

    return num_entries_removed;
}

pub const PostQueuedCompletionStatusError = error{Unexpected};

pub fn PostQueuedCompletionStatus(
    completion_port: HANDLE,
    bytes_transferred_count: DWORD,
    completion_key: usize,
    lpOverlapped: ?*OVERLAPPED,
) PostQueuedCompletionStatusError!void {
    if (kernel32.PostQueuedCompletionStatus(completion_port, bytes_transferred_count, completion_key, lpOverlapped) == .FALSE) {
        switch (kernel32.GetLastError()) {
            else => |err| return unexpectedError(err),
        }
    }
}

pub fn CreateIoCompletionPort(
    file_handle: HANDLE,
    existing_completion_port: ?HANDLE,
    completion_key: usize,
    concurrent_thread_count: DWORD,
) error{Unexpected}!HANDLE {
    const handle = kernel32.CreateIoCompletionPort(file_handle, existing_completion_port, completion_key, concurrent_thread_count) orelse {
        switch (kernel32.GetLastError()) {
            .INVALID_PARAMETER => unreachable,
            else => |err| return unexpectedError(err),
        }
    };
    return handle;
}

var wsa_initialized: bool = false;

fn callWSAStartup() !void {
    if (@atomicLoad(bool, &wsa_initialized, .acquire)) return;

    var wsadata: ws2_32.WSADATA = undefined;
    const rc = ws2_32.WSAStartup(0x0202, &wsadata);
    if (rc != 0) return error.Unexpected;

    @atomicStore(bool, &wsa_initialized, true, .release);
}

pub fn WSASocketW(
    af: i32,
    socket_type: i32,
    protocol: i32,
    protocolInfo: ?*ws2_32.WSAPROTOCOL_INFOW,
    g: u32,
    dwFlags: DWORD,
) !ws2_32.SOCKET {
    var first = true;
    while (true) {
        const rc = ws2_32.WSASocketW(af, socket_type, protocol, protocolInfo, g, dwFlags);
        if (rc == ws2_32.INVALID_SOCKET) {
            switch (ws2_32.WSAGetLastError()) {
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                .WSAENOBUFS => return error.SystemResources,
                .WSAEPROTONOSUPPORT => return error.ProtocolNotSupported,
                .WSANOTINITIALISED => {
                    if (!first) return error.Unexpected;
                    first = false;
                    try callWSAStartup();
                    continue;
                },
                else => |err| return unexpectedWSAError(err),
            }
        }
        return rc;
    }
}

pub fn sliceToPrefixedFileW(dir: ?HANDLE, path: []const u8) error{ InvalidWtf8, BadPathName, NameTooLong, Unexpected, AccessDenied, FileNotFound }!PathSpace {
    _ = dir;
    var result: PathSpace = undefined;
    result.len = std.unicode.wtf8ToWtf16Le(&result.data, path) catch return error.InvalidWtf8;
    result.data[result.len] = 0;
    return result;
}

pub const PathSpace = struct {
    data: [260]u16,
    len: usize,

    pub fn span(self: *const PathSpace) [:0]const u16 {
        return self.data[0..self.len :0];
    }
};

pub const exp = struct {
    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const JOBOBJECT_ASSOCIATE_COMPLETION_PORT = extern struct {
        CompletionKey: win.ULONG_PTR,
        CompletionPort: win.HANDLE,
    };

    pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: win.LARGE_INTEGER,
        PerJobUserTimeLimit: win.LARGE_INTEGER,
        LimitFlags: win.DWORD,
        MinimumWorkingSetSize: win.SIZE_T,
        MaximumWorkingSetSize: win.SIZE_T,
        ActiveProcessLimit: win.DWORD,
        Affinity: win.ULONG_PTR,
        PriorityClass: win.DWORD,
        SchedulingClass: win.DWORD,
    };

    pub const IO_COUNTERS = extern struct {
        ReadOperationCount: win.ULONGLONG,
        WriteOperationCount: win.ULONGLONG,
        OtherOperationCount: win.ULONGLONG,
        ReadTransferCount: win.ULONGLONG,
        WriteTransferCount: win.ULONGLONG,
        OtherTransferCount: win.ULONGLONG,
    };

    pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: win.SIZE_T,
        JobMemoryLimit: win.SIZE_T,
        PeakProcessMemoryUsed: win.SIZE_T,
        PeakJobMemoryUsed: win.SIZE_T,
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

    pub const JOB_OBJECT_MSG_TYPE = enum(win.DWORD) {
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

    pub const k32 = struct {
        pub extern "kernel32" fn GetProcessId(Process: win.HANDLE) callconv(.winapi) win.DWORD;
        pub extern "kernel32" fn CreateJobObjectA(lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES, lpName: ?win.LPCSTR) callconv(.winapi) win.HANDLE;
        pub extern "kernel32" fn AssignProcessToJobObject(hJob: win.HANDLE, hProcess: win.HANDLE) callconv(.winapi) win.BOOL;
        pub extern "kernel32" fn SetInformationJobObject(
            hJob: win.HANDLE,
            JobObjectInformationClass: JOBOBJECT_INFORMATION_CLASS,
            lpJobObjectInformation: win.LPVOID,
            cbJobObjectInformationLength: win.DWORD,
        ) callconv(.winapi) win.BOOL;
    };

    pub const CreateFileError = error{} || posix.UnexpectedError;

    pub fn CreateFile(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: win.DWORD,
        dwShareMode: win.DWORD,
        lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES,
        dwCreationDisposition: win.DWORD,
        dwFlagsAndAttributes: win.DWORD,
        hTemplateFile: ?win.HANDLE,
    ) CreateFileError!win.HANDLE {
        const handle = kernel32.CreateFileW(lpFileName, dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
        if (handle == win.INVALID_HANDLE_VALUE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                else => unexpectedError(err),
            };
        }

        return handle;
    }

    pub fn ReadFile(
        handle: win.HANDLE,
        buffer: []u8,
        overlapped: ?*OVERLAPPED,
    ) ReadFileError!?usize {
        var read: win.DWORD = 0;
        const result = kernel32.ReadFile(handle, buffer.ptr, @as(win.DWORD, @intCast(buffer.len)), &read, overlapped);
        if (result == .FALSE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                .IO_PENDING => null,
                else => unexpectedError(err),
            };
        }

        return @as(usize, @intCast(read));
    }

    pub fn WriteFile(
        handle: win.HANDLE,
        buffer: []const u8,
        overlapped: ?*OVERLAPPED,
    ) WriteFileError!?usize {
        var written: win.DWORD = 0;
        const result = kernel32.WriteFile(handle, buffer.ptr, @as(win.DWORD, @intCast(buffer.len)), &written, overlapped);
        if (result == .FALSE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                .IO_PENDING => null,
                else => unexpectedError(err),
            };
        }

        return @as(usize, @intCast(written));
    }

    pub const DeleteFileError = error{} || posix.UnexpectedError;

    pub fn DeleteFile(name: [*:0]const u16) DeleteFileError!void {
        const result = kernel32.DeleteFileW(name);
        if (result == .FALSE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                else => unexpectedError(err),
            };
        }
    }

    pub const CreateJobObjectError = error{AlreadyExists} || posix.UnexpectedError;
    pub fn CreateJobObject(
        lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES,
        lpName: ?win.LPCSTR,
    ) !win.HANDLE {
        const handle = exp.k32.CreateJobObjectA(lpSecurityAttributes, lpName);
        return switch (kernel32.GetLastError()) {
            .SUCCESS => handle,
            .ALREADY_EXISTS => CreateJobObjectError.AlreadyExists,
            else => |err| unexpectedError(err),
        };
    }

    pub fn AssignProcessToJobObject(hJob: win.HANDLE, hProcess: win.HANDLE) posix.UnexpectedError!void {
        const result = exp.k32.AssignProcessToJobObject(hJob, hProcess);
        if (result == .FALSE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                else => unexpectedError(err),
            };
        }
    }

    pub fn SetInformationJobObject(
        hJob: win.HANDLE,
        JobObjectInformationClass: JOBOBJECT_INFORMATION_CLASS,
        lpJobObjectInformation: win.LPVOID,
        cbJobObjectInformationLength: win.DWORD,
    ) posix.UnexpectedError!void {
        const result = exp.k32.SetInformationJobObject(
            hJob,
            JobObjectInformationClass,
            lpJobObjectInformation,
            cbJobObjectInformationLength,
        );

        if (result == .FALSE) {
            const err = kernel32.GetLastError();
            return switch (err) {
                else => unexpectedError(err),
            };
        }
    }
};
