const std = @import("std");
const assert = std.debug.assert;
const os = std.os;

/// TCP client and server.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn TCP(comptime xev: type) type {
    return struct {
        const Self = @This();

        socket: os.socket_t,

        /// Initialize a new TCP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            return .{
                .socket = try os.socket(
                    addr.any.family,
                    os.SOCK.NONBLOCK | os.SOCK.STREAM | os.SOCK.CLOEXEC,
                    0,
                ),
            };
        }

        /// Initialize a TCP socket from a file descriptor.
        pub fn initFd(fd: os.socket_t) Self {
            return .{
                .socket = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            try os.setsockopt(self.socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try os.bind(self.socket, &addr.any, addr.getOsSockLen());
        }

        /// Listen for connections on the socket. This puts the socket into passive
        /// listening mode. Connections must still be accepted one at a time.
        pub fn listen(self: Self, backlog: u31) !void {
            try os.listen(self.socket, backlog);
        }

        /// Accept a single connection.
        pub fn accept(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: AcceptError!Self,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .accept = .{
                        .socket = self.socket,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
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
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            addr: std.net.Address,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: ConnectError!void,
            ) xev.CallbackAction,
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
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            initFd(c_inner.op.connect.socket),
                            if (r.connect) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Close the socket.
        pub fn close(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: CloseError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .close = .{
                        .fd = self.socket,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            initFd(c_inner.op.close.fd),
                            if (r.close) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Shutdown the socket. This always only shuts down the writer side. You
        /// can use the lower level interface directly to control this if the
        /// platform supports it.
        pub fn shutdown(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: ShutdownError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .shutdown = .{
                        .socket = self.socket,
                        .flags = std.os.linux.SHUT.WR,
                    },
                },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            initFd(c_inner.op.shutdown.socket),
                            if (r.shutdown) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Read from the socket. This performs a single read. The callback must
        /// requeue the read if additional reads want to be performed. Additional
        /// reads simultaneously can be queued by calling this multiple times. Note
        /// that depending on the backend, the reads can happen out of order.
        pub fn read(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            buf: xev.ReadBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                b: xev.ReadBuffer,
                r: ReadError!usize,
            ) xev.CallbackAction,
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
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                return @call(.always_inline, cb, .{
                                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                                    l_inner,
                                    c_inner,
                                    initFd(c_inner.op.recv.fd),
                                    c_inner.op.recv.buffer,
                                    if (r.recv) |v| v else |err| err,
                                });
                            }
                        }).callback,
                    };

                    loop.add(c);
                },
            }
        }

        /// Write to the socket. This performs a single write. Additional writes
        /// can be queued by calling this multiple times. Note that depending on the
        /// backend, writes can happen out of order.
        pub fn write(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            buf: xev.WriteBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                b: xev.WriteBuffer,
                r: WriteError!usize,
            ) xev.CallbackAction,
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
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                return @call(.always_inline, cb, .{
                                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                                    l_inner,
                                    c_inner,
                                    initFd(c_inner.op.send.fd),
                                    c_inner.op.send.buffer,
                                    if (r.send) |v| v else |err| err,
                                });
                            }
                        }).callback,
                    };

                    loop.add(c);
                },
            }
        }

        pub const AcceptError = xev.Loop.AcceptError;
        pub const CloseError = xev.Loop.CloseError;
        pub const ConnectError = xev.Loop.ConnectError;
        pub const ShutdownError = xev.Loop.ShutdownError;
        pub const ReadError = xev.Loop.ReadError;
        pub const WriteError = xev.Loop.WriteError;

        test "TCP: accept/connect/send/recv/close" {
            const testing = std.testing;

            var loop = try xev.Loop.init(16);
            defer loop.deinit();

            const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
            const server = try Self.init(address);
            const client = try Self.init(address);

            // Completions we need
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;

            // Bind and accept
            try server.bind(address);
            try server.listen(1);
            var server_conn: ?Self = null;
            server.accept(&loop, &c_accept, ?Self, &server_conn, (struct {
                fn callback(
                    ud: ?*?Self,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: AcceptError!Self,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Connect
            var connected: bool = false;
            client.connect(&loop, &c_connect, address, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    r: ConnectError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for the connection to be established
            try loop.run(.until_done);
            try testing.expect(server_conn != null);
            try testing.expect(connected);

            // Close the server
            var server_closed = false;
            server.close(&loop, &c_accept, bool, &server_closed, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    r: CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);
            try testing.expect(server_closed);

            // Send
            var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            client.write(&loop, &c_connect, .{ .slice = &send_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    c: *xev.Completion,
                    _: Self,
                    _: xev.WriteBuffer,
                    r: WriteError!usize,
                ) xev.CallbackAction {
                    _ = c;
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Receive
            var recv_buf: [128]u8 = undefined;
            var recv_len: usize = 0;
            server_conn.?.read(&loop, &c_accept, .{ .slice = &recv_buf }, usize, &recv_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.ReadBuffer,
                    r: ReadError!usize,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the send/receive
            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &send_buf, recv_buf[0..recv_len]);

            // Close
            server_conn.?.close(&loop, &c_accept, ?Self, &server_conn, (struct {
                fn callback(
                    ud: ?*?Self,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    r: CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = null;
                    return .disarm;
                }
            }).callback);
            client.close(&loop, &c_connect, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    r: CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = false;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(server_conn == null);
            try testing.expect(!connected);
            try testing.expect(server_closed);
        }
    };
}
