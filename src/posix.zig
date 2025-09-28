const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const native_os = builtin.target.os.tag;

// Struct aliases for convenience
pub const msghdr = posix.msghdr;
pub const msghdr_const = posix.msghdr_const;

pub const RecvMsgError = error{
    /// The socket is marked nonblocking and the requested operation would block, and
    /// there is no global event loop configured.
    WouldBlock,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Could not allocate kernel memory.
    SystemResources,

    ConnectionResetByPeer,

    /// The message was too big for the buffer and part of it has been discarded
    MessageTooBig,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The local end has been shut down on a connection oriented socket.
    BrokenPipe,
} || posix.UnexpectedError;

/// Wrapper around recvmsg that properly handles errors including EINTR.
/// Similar to std.posix.recvfrom but for recvmsg.
/// On Linux, uses direct syscall instead of libc.
pub fn recvmsg(
    sockfd: posix.socket_t,
    msg: *msghdr,
    flags: u32,
) RecvMsgError!usize {
    if (native_os == .windows) {
        @compileError("recvmsg is not supported on Windows");
    }

    while (true) {
        const rc = if (native_os == .linux)
            linux.recvmsg(sockfd, msg, flags)
        else
            std.c.recvmsg(sockfd, msg, @intCast(flags));

        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable, // always a race condition
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INTR => continue,
            .FAULT => unreachable, // An invalid user space address was specified for an argument.
            .INVAL => unreachable, // Invalid argument passed.
            .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .MSGSIZE => return error.MessageTooBig,
            .PIPE => return error.BrokenPipe,
            .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
            .CONNRESET => return error.ConnectionResetByPeer,
            .NETDOWN => return error.NetworkSubsystemFailed,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
