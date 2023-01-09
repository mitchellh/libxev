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

/// Shutdown the socket. This always only shuts down the writer side. You
/// can use the lower level interface directly to control this if the
/// platform supports it.
pub fn shutdown(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .shutdown = .{
                .socket = self.socket,
                .flags = std.os.linux.SHUT.WR,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}

/// Read from the socket. This performs a single read. The callback must
/// requeue the read if additional reads want to be performed. Additional
/// reads simultaneously can be queued by calling this multiple times. Note
/// that depending on the backend, the reads can happen out of order.
pub fn read(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    buf: xev.ReadBuffer,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    switch (buf) {
        inline .slice, .array => {
            c.* = .{
                .op = .{
                    .recv = .{
                        .fd = self.socket,
                        .buffer = buf,
                    },
                },
                .userdata = userdata,
                .callback = cb,
            };

            loop.add(c);
        },
    }
}

/// Write to the socket. This performs a single write. Additional writes
/// can be queued by calling this multiple times. Note that depending on the
/// backend, writes can happen out of order.
pub fn write(
    self: Socket,
    loop: *xev.Loop,
    c: *xev.Completion,
    buf: xev.WriteBuffer,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    switch (buf) {
        inline .slice, .array => {
            c.* = .{
                .op = .{
                    .send = .{
                        .fd = self.socket,
                        .buffer = buf,
                    },
                },
                .userdata = userdata,
                .callback = cb,
            };

            loop.add(c);
        },
    }
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

    // Send
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    client.write(&loop, &c_connect, .{ .slice = &send_buf }, null, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.send catch unreachable;
            _ = ud;
        }
    }).callback);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    server_conn.?.read(&loop, &c_accept, .{ .slice = &recv_buf }, &recv_len, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
            ptr.* = r.recv catch unreachable;
        }
    }).callback);

    // Wait for the send/receive
    while (recv_len == 0) try loop.tick();
    try testing.expectEqualSlices(u8, &send_buf, recv_buf[0..recv_len]);

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
