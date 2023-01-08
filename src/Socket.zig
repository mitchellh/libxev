/// Create and perform operations on sockets (TCP, UDP, Unix Domains, etc.).
/// This is a high-level helper to create a socket suitable for the event
/// loop and perform operations on it.
///
/// If you want specific control over the socket, you can always create a
/// socket yourself and use raw Completions directly with the Loop to setup
/// async operations. For common use cases, you should just use this
/// abstraction -- there is almost no overhead.
pub const Socket = @This();

const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

/// Address to connect to for a client or to listen on for a server.
address: std.net.Address,

/// The socket file descriptor.
socket: std.os.socket_t,

/// Create a generic new socket for a given address. The socket can still
/// be a client or server.
pub fn init(addr: std.net.Address) !Socket {
    return .{
        .address = addr,
        .socket = try os.socket(addr.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0),
    };
}

/// Initialize a Socket from a file descriptor.
///
/// When this is used, the following functions can NOT be called:
///   - bind
///   - connect
///
pub fn initFd(fd: os.socket_t) Socket {
    return .{
        .address = undefined,
        .socket = fd,
    };
}

/// Bind the address to the socket.
pub fn bind(self: Socket) !void {
    try os.setsockopt(
        self.socket,
        os.SOL.SOCKET,
        os.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    try os.bind(self.socket, &self.address.any, self.address.getOsSockLen());
}

/// Listen for connections on the socket. This puts the socket into passive
/// listening mode. Connections must still be accepted one at a time.
pub fn listen(self: Socket, backlog: u31) !void {
    try os.listen(self.socket, backlog);
}

/// Accept a single connection. This must be called again in the callback
/// if you want to continue accepting more connections.
pub fn accept(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .accept = .{
                .socket = self.socket,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}

/// Establish a connection as a client.
pub fn connect(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .connect = .{
                .socket = self.socket,
                .addr = self.address,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}

/// Close the socket.
pub fn close(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .close = .{
                .fd = self.socket,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}

test "socket: accept/connect/send/recv/close" {
    const testing = std.testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    const server = try Socket.init(address);
    const client = try Socket.init(address);

    // Completions we need
    var c_accept: xev.Completion = undefined;
    var c_connect: xev.Completion = undefined;

    // Bind and accept
    try server.bind();
    try server.listen(1);
    var server_conn: ?Socket = null;
    server.accept(&loop, &c_accept, &server_conn, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            const ptr = @ptrCast(*?Socket, @alignCast(@alignOf(?Socket), ud.?));
            ptr.* = Socket.initFd(r.accept catch unreachable);
        }
    }).callback);

    // Connect
    var connected: bool = false;
    client.connect(&loop, &c_connect, &connected, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.connect catch unreachable;
            const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
            ptr.* = true;
        }
    }).callback);

    // Wait for the connection to be established
    while (server_conn == null or !connected) try loop.tick();
    try testing.expect(server_conn != null);
    try testing.expect(connected);

    // Close
    server_conn.?.close(&loop, &c_accept, &server_conn, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.close catch unreachable;
            const ptr = @ptrCast(*?Socket, @alignCast(@alignOf(?Socket), ud.?));
            ptr.* = null;
        }
    }).callback);
    client.close(&loop, &c_connect, &connected, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.close catch unreachable;
            const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
            ptr.* = false;
        }
    }).callback);

    while (server_conn != null or connected) try loop.tick();
}
