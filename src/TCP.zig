/// TCP client and server.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub const TCP = @This();

const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

socket: os.socket_t,

/// Initialize a new TCP with the family from the given address. Only
/// the family is used, the actual address has no impact on the created
/// resource.
pub fn init(addr: std.net.Address) !TCP {
    return .{
        .socket = try os.socket(addr.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0),
    };
}

/// Initialize a TCP socket from a file descriptor.
pub fn initFd(fd: os.socket_t) TCP {
    return .{
        .socket = fd,
    };
}

/// Bind the address to the socket.
pub fn bind(self: TCP, addr: std.net.Address) !void {
    try os.setsockopt(self.socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(self.socket, &addr.any, addr.getOsSockLen());
}

/// Listen for connections on the socket. This puts the socket into passive
/// listening mode. Connections must still be accepted one at a time.
pub fn listen(self: TCP, backlog: u31) !void {
    try os.listen(self.socket, backlog);
}

/// Accept a single connection.
pub fn accept(
    self: TCP,
    loop: *xev.Loop,
    c: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: AcceptError!TCP,
    ) void,
) void {
    c.* = .{
        .op = .{
            .accept = .{
                .socket = self.socket,
            },
        },

        .userdata = userdata,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
                @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                    c_inner,
                    if (r.accept) |fd| initFd(fd) else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}

/// Establish a connection as a client.
pub fn connect(
    self: TCP,
    loop: *xev.Loop,
    c: *xev.Completion,
    addr: std.net.Address,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: ConnectError!void,
    ) void,
) void {
    c.* = .{
        .op = .{
            .connect = .{
                .socket = self.socket,
                .addr = addr,
            },
        },

        .userdata = userdata,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
                @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                    c_inner,
                    if (r.connect) |_| {} else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}

/// Close the socket.
pub fn close(
    self: TCP,
    loop: *xev.Loop,
    c: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: CloseError!void,
    ) void,
) void {
    c.* = .{
        .op = .{
            .close = .{
                .fd = self.socket,
            },
        },

        .userdata = userdata,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
                @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                    c_inner,
                    if (r.close) |_| {} else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}
pub const AcceptError = xev.Loop.AcceptError;
pub const CloseError = xev.Loop.CloseError;
pub const ConnectError = xev.Loop.ConnectError;

test "TCP: accept/connect/send/recv/close" {
    const testing = std.testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    const server = try TCP.init(address);
    const client = try TCP.init(address);

    // Completions we need
    var c_accept: xev.Completion = undefined;
    var c_connect: xev.Completion = undefined;

    // Bind and accept
    try server.bind(address);
    try server.listen(1);
    var server_conn: ?TCP = null;
    server.accept(&loop, &c_accept, ?TCP, &server_conn, (struct {
        fn callback(ud: ?*?TCP, c: *xev.Completion, r: AcceptError!TCP) void {
            _ = c;
            ud.?.* = r catch unreachable;
        }
    }).callback);

    // Connect
    var connected: bool = false;
    client.connect(&loop, &c_connect, address, bool, &connected, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: ConnectError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_conn != null);
    try testing.expect(connected);

    // Close the server
    var server_closed = false;
    server.close(&loop, &c_accept, bool, &server_closed, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: CloseError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);
    try loop.run(.until_done);
    try testing.expect(server_closed);

    // Close
    server_conn.?.close(&loop, &c_accept, ?TCP, &server_conn, (struct {
        fn callback(ud: ?*?TCP, c: *xev.Completion, r: CloseError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = null;
        }
    }).callback);
    client.close(&loop, &c_connect, bool, &connected, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: CloseError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = false;
        }
    }).callback);

    try loop.run(.until_done);
    try testing.expect(server_conn == null);
    try testing.expect(!connected);
    try testing.expect(server_closed);
}
