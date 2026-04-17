//! A lot of compatibility shims over the years of Zig updates
//! for removed functions from Zig 0.15, 0.16, etc.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;
const maxInt = std.math.maxInt;

pub const net = struct {
    pub const Address = extern union {
        any: posix.sockaddr,
        in: posix.sockaddr.in,
        in6: posix.sockaddr.in6,

        pub fn parseIp4(text: []const u8, port: u16) !Address {
            return initIp4((try std.Io.net.Ip4Address.parse(text, port)).bytes, port);
        }

        pub fn parseIp6(text: []const u8, port: u16) !Address {
            const ip6 = try std.Io.net.Ip6Address.parse(text, port);
            var result: Address = undefined;
            result.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return result;
        }

        pub fn initIp4(bytes: [4]u8, port: u16) Address {
            var result: Address = undefined;
            result.in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast(bytes),
            };
            return result;
        }

        pub fn initPosix(addr: *const posix.sockaddr) Address {
            var result: Address = undefined;
            switch (addr.family) {
                posix.AF.INET => result.in = (@as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)))).*,
                posix.AF.INET6 => result.in6 = (@as(*const posix.sockaddr.in6, @ptrCast(@alignCast(addr)))).*,
                else => result.any = addr.*,
            }
            return result;
        }

        pub fn getOsSockLen(self: Address) posix.socklen_t {
            return switch (self.any.family) {
                posix.AF.INET => @sizeOf(posix.sockaddr.in),
                posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
                else => @sizeOf(posix.sockaddr),
            };
        }

        pub fn toIpAddress(self: Address) std.Io.net.IpAddress {
            return switch (self.any.family) {
                posix.AF.INET => .{ .ip4 = .{
                    .bytes = @bitCast(self.in.addr),
                    .port = std.mem.bigToNative(u16, self.in.port),
                } },
                posix.AF.INET6 => .{ .ip6 = .{
                    .bytes = self.in6.addr,
                    .port = std.mem.bigToNative(u16, self.in6.port),
                    .flow = self.in6.flowinfo,
                    .interface = .{ .index = self.in6.scope_id },
                } },
                else => unreachable,
            };
        }

        pub fn fromIpAddress(addr: std.Io.net.IpAddress) Address {
            return switch (addr) {
                .ip4 => |ip4| initIp4(ip4.bytes, ip4.port),
                .ip6 => |ip6| fromIp6Address(ip6),
            };
        }

        pub fn fromIp6Address(ip6: std.Io.net.Ip6Address) Address {
            var result: Address = undefined;
            result.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return result;
        }
    };
};

pub const ReadError = error{
    AccessDenied,
    InputOutput,
    IsDir,
    NotOpenForReading,
    ProcessNotFound,
    SocketNotConnected,
    SystemResources,
    WouldBlock,
    ConnectionResetByPeer,
    ConnectionTimedOut,
} || posix.UnexpectedError;

pub const PReadError = ReadError || error{Unseekable};

pub const WriteError = error{
    AccessDenied,
    BrokenPipe,
    DeviceBusy,
    DiskQuota,
    FileTooBig,
    InputOutput,
    InvalidArgument,
    MessageTooBig,
    NoSpaceLeft,
    NotOpenForWriting,
    PermissionDenied,
    ProcessNotFound,
    SystemResources,
    WouldBlock,
    ConnectionResetByPeer,
} || posix.UnexpectedError;

pub const PWriteError = WriteError || error{Unseekable};

pub const SendError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressNotAvailable,
    BrokenPipe,
    ConnectionRefused,
    ConnectionResetByPeer,
    FileNotFound,
    MessageTooBig,
    NameTooLong,
    NetworkSubsystemFailed,
    NetworkUnreachable,
    NotDir,
    SocketNotConnected,
    SymLinkLoop,
    SystemResources,
    UnreachableAddress,
    WouldBlock,
} || posix.UnexpectedError;

pub const RecvFromError = error{
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    MessageTooBig,
    NetworkSubsystemFailed,
    SocketNotBound,
    SocketNotConnected,
    SystemResources,
    WouldBlock,
} || posix.UnexpectedError;

pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProcessFdQuotaExceeded,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    SystemFdQuotaExceeded,
    SystemResources,
} || posix.UnexpectedError;

pub const BindError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    AlreadyBound,
    FileNotFound,
    NameTooLong,
    NotDir,
    ReadOnlyFileSystem,
    SymLinkLoop,
    SystemResources,
} || posix.UnexpectedError;

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    SocketNotBound,
    SystemResources,
} || posix.UnexpectedError;

pub const PipeError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || posix.UnexpectedError;

pub const AcceptError = std.Io.net.Server.AcceptError;

pub const GetSockNameError = error{
    FileDescriptorNotASocket,
    SocketNotBound,
    SystemResources,
} || posix.UnexpectedError;

pub const ConnectError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    FileNotFound,
    NetworkUnreachable,
    PermissionDenied,
    SystemResources,
    WouldBlock,
} || posix.UnexpectedError;

pub fn connect(sock: posix.socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    while (true) {
        switch (posix.errno(system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .INTR => continue,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE, .CONNABORTED => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn getsockoptError(sockfd: posix.fd_t) ConnectError!void {
    const E = std.posix.E;
    const SOL = if (@hasDecl(std.posix, "SOL")) std.posix.SOL else std.os.linux.SOL;
    const SO = if (@hasDecl(std.posix, "SO")) std.posix.SO else std.os.linux.SO;
    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = system.getsockopt(sockfd, SOL.SOCKET, SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (posix.errno(rc)) {
        .SUCCESS => switch (@as(E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        },
        .BADF, .FAULT, .INVAL => unreachable,
        .NOPROTOOPT, .NOTSOCK => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn dup(old_fd: posix.fd_t) !posix.fd_t {
    const rc = system.dup(old_fd);
    return switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .BADF => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    };
}

pub fn close(fd: posix.fd_t) void {
    switch (posix.errno(system.close(fd))) {
        .SUCCESS, .INTR => {},
        .BADF => unreachable,
        else => unreachable,
    }
}

pub fn setCloexec(fd: posix.fd_t) !void {
    while (true) switch (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn getStatusFlags(fd: posix.fd_t) !u32 {
    while (true) {
        const rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setStatusFlags(fd: posix.fd_t, flags: u32) !void {
    while (true) switch (posix.errno(system.fcntl(fd, posix.F.SETFL, flags))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn setSockFlags(sock: posix.socket_t, flags: u32) !void {
    if ((flags & posix.SOCK.CLOEXEC) != 0) try setCloexec(sock);
    if ((flags & posix.SOCK.NONBLOCK) != 0) {
        const current = try getStatusFlags(sock);
        try setStatusFlags(sock, current | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    }
}

pub fn accept(
    sock: posix.socket_t,
    addr: *posix.sockaddr,
    addr_size: *posix.socklen_t,
    flags: u32,
) AcceptError!posix.socket_t {
    while (true) {
        const rc = system.accept(sock, addr, addr_size);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.socket_t = @intCast(rc);
                if (flags & posix.SOCK.CLOEXEC != 0) try setCloexec(fd);
                return fd;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    const have_sock_flags = !builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .haiku;
    const filtered_sock_type = if (have_sock_flags)
        socket_type
    else
        socket_type & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);

    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            const fd: posix.socket_t = @intCast(rc);
            errdefer close(fd);
            if (!have_sock_flags) try setSockFlags(fd, socket_type);
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolNotSupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    switch (posix.errno(system.bind(sock, addr, len))) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .INVAL => return error.AlreadyBound,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .FAULT, .NOTSOCK => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn listen(sock: posix.socket_t, backlog: u31) ListenError!void {
    switch (posix.errno(system.listen(sock, backlog))) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .INVAL => return error.SocketNotBound,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        .BADF => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn getsockname(sock: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) GetSockNameError!void {
    switch (posix.errno(system.getsockname(sock, addr, addrlen))) {
        .SUCCESS => return,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        .BADF, .FAULT, .INVAL => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    while (true) {
        const rc = system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .FAULT, .DESTADDRREQ => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn read(fd: posix.fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .FAULT, .INVAL => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn pwrite(fd: posix.fd_t, bytes: []const u8, offset: u64) PWriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    const pwrite_fn = if (builtin.target.os.tag == .linux and !builtin.target.abi.isMusl() and @hasDecl(system, "pwrite64")) system.pwrite64 else system.pwrite;
    while (true) {
        const rc = pwrite_fn(fd, bytes.ptr, @min(bytes.len, max_count), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .BUSY => return error.DeviceBusy,
            .NXIO, .SPIPE, .OVERFLOW => return error.Unseekable,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .FAULT, .DESTADDRREQ => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn pread(fd: posix.fd_t, buf: []u8, offset: u64) PReadError!usize {
    if (buf.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    const pread_fn = if (builtin.target.os.tag == .linux and !builtin.target.abi.isMusl() and @hasDecl(system, "pread64")) system.pread64 else system.pread;
    while (true) {
        const rc = pread_fn(fd, buf.ptr, @min(buf.len, max_count), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NXIO, .SPIPE, .OVERFLOW => return error.Unseekable,
            .FAULT, .INVAL => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn send(sockfd: posix.socket_t, buf: []const u8, flags: u32) SendError!usize {
    return sendto(sockfd, buf, flags, null, 0) catch |err| switch (err) {
        error.AddressFamilyNotSupported,
        error.AddressNotAvailable,
        error.FileNotFound,
        error.NameTooLong,
        error.NotDir,
        error.SymLinkLoop,
        error.UnreachableAddress,
        => unreachable,
        else => |e| return e,
    };
}

pub fn sendto(
    sockfd: posix.socket_t,
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const posix.sockaddr,
    addrlen: posix.socklen_t,
) SendError!usize {
    while (true) {
        const rc = system.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .INTR => continue,
            .INVAL => return error.UnreachableAddress,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PIPE => return error.BrokenPipe,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketNotConnected,
            .NETDOWN => return error.NetworkSubsystemFailed,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .BADF, .DESTADDRREQ, .FAULT, .ISCONN, .NOTSOCK, .OPNOTSUPP => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const SendMsgError = SendError;

pub fn sendmsg(sockfd: posix.socket_t, msg: *const std.os.linux.msghdr_const, flags: u32) SendError!usize {
    while (true) {
        const rc = system.sendmsg(sockfd, @ptrCast(msg), flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .INTR => continue,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PIPE => return error.BrokenPipe,
            .NOTCONN => return error.SocketNotConnected,
            .NETDOWN => return error.NetworkSubsystemFailed,
            .NETUNREACH, .HOSTUNREACH => return error.NetworkUnreachable,
            .BADF, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .NOTSOCK, .OPNOTSUPP => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn recv(sockfd: posix.socket_t, buf: []u8, flags: u32) RecvFromError!usize {
    return recvfrom(sockfd, buf, flags, null, null);
}

pub fn recvfrom(
    sockfd: posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
) RecvFromError!usize {
    while (true) {
        const rc = system.recvfrom(sockfd, buf.ptr, buf.len, flags, src_addr, addrlen);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .NOTCONN => return error.SocketNotConnected,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .NOMEM => return error.SystemResources,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .BADF, .FAULT, .INVAL, .NOTSOCK => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn pipe2(flags: posix.O) PipeError![2]posix.fd_t {
    if (!builtin.target.os.tag.isDarwin() and @hasDecl(system, "pipe2")) {
        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .FAULT => unreachable,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(system.pipe(&fds))) {
        .SUCCESS => {},
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .INVAL, .FAULT => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    if (flags.CLOEXEC) {
        try setCloexec(fds[0]);
        try setCloexec(fds[1]);
    }

    var status_flags = flags;
    status_flags.CLOEXEC = false;
    const status_flags_int = @as(u32, @bitCast(status_flags));
    if (status_flags_int != 0) {
        try setStatusFlags(fds[0], status_flags_int);
        try setStatusFlags(fds[1], status_flags_int);
    }

    return fds;
}
