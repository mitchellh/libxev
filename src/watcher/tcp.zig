const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const stream = @import("stream.zig");
const common = @import("common.zig");

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
        const FdType = if (xev.backend == .iocp) std.os.windows.HANDLE else posix.socket_t;

        fd: FdType,

        pub usingnamespace stream.Stream(xev, Self, .{
            .close = true,
            .read = .recv,
            .write = .send,
        });

        /// Initialize a new TCP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            if (xev.backend == .wasi_poll) @compileError("unsupported in WASI");

            const fd = if (xev.backend == .iocp)
                try std.os.windows.WSASocketW(addr.any.family, posix.SOCK.STREAM, 0, null, 0, std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED)
            else fd: {
                // On io_uring we don't use non-blocking sockets because we may
                // just get EAGAIN over and over from completions.
                const flags = flags: {
                    var flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
                    if (xev.backend != .io_uring) flags |= posix.SOCK.NONBLOCK;
                    break :flags flags;
                };
                break :fd try posix.socket(addr.any.family, flags, 0);
            };

            return .{
                .fd = fd,
            };
        }

        /// Initialize a TCP socket from a file descriptor.
        pub fn initFd(fd: FdType) Self {
            return .{
                .fd = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            if (xev.backend == .wasi_poll) @compileError("unsupported in WASI");

            const fd = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.fd)) else self.fd;

            try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(fd, &addr.any, addr.getOsSockLen());
        }

        /// Listen for connections on the socket. This puts the socket into passive
        /// listening mode. Connections must still be accepted one at a time.
        pub fn listen(self: Self, backlog: u31) !void {
            if (xev.backend == .wasi_poll) @compileError("unsupported in WASI");

            const fd = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.fd)) else self.fd;

            try posix.listen(fd, backlog);
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
                        .socket = self.fd,
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
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.accept) |fd| initFd(fd) else |err| err,
                        });
                    }
                }).callback,
            };

            // If we're dup-ing, then we ask the backend to manage the fd.
            switch (xev.backend) {
                .io_uring,
                .kqueue,
                .wasi_poll,
                .iocp,
                => {},

                .epoll => c.flags.dup = true,
            }

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
            if (xev.backend == .wasi_poll) @compileError("unsupported in WASI");

            c.* = .{
                .op = .{
                    .connect = .{
                        .socket = self.fd,
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
                            common.userdataValue(Userdata, ud),
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
                        .socket = self.fd,
                        .how = .send,
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
                            common.userdataValue(Userdata, ud),
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

        pub const AcceptError = xev.AcceptError;
        pub const ConnectError = xev.ConnectError;
        pub const ShutdownError = xev.ShutdownError;

        test "TCP: accept/connect/send/recv/close" {
            // We have no way to get a socket in WASI from a WASI context.
            if (xev.backend == .wasi_poll) return error.SkipZigTest;

            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Choose random available port (Zig #14907)
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Self.init(address);

            // Bind and listen
            try server.bind(address);
            try server.listen(1);

            // Retrieve bound port and initialize client
            var sock_len = address.getOsSockLen();
            const fd = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(server.fd)) else server.fd;
            try posix.getsockname(fd, &address.any, &sock_len);
            const client = try Self.init(address);

            //const address = try std.net.Address.parseIp4("127.0.0.1", 3132);
            //var server = try Self.init(address);
            //var client = try Self.init(address);

            // Completions we need
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;

            // Accept
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
                    r: Self.CloseError!void,
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
                    r: Self.WriteError!usize,
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
                    r: Self.ReadError!usize,
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
                    r: Self.CloseError!void,
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
                    r: Self.CloseError!void,
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

        // Potentially flaky - this test could hang if the sender is unable to
        // write everything to the socket for whatever reason
        // (e.g. incorrectly sized buffer on the receiver side), or if the
        // receiver is trying to receive while sender has nothing left to send.
        //
        // Overview:
        // 1. Set up server and client sockets
        // 2. connect & accept, set SO_SNDBUF to 8kB on the client
        // 3. Try to send 1MB buffer from client to server without queuing, this _should_ fail
        //    and theoretically send <= 8kB, but in practice, it seems to write ~32kB.
        //    Asserts that <= 100kB was written
        // 4. Set up a queued write with the remaining buffer, shutdown() the socket afterwards
        // 5. Set up a receiver that loops until it receives the entire buffer
        // 6. Assert send_buf == recv_buf
        test "TCP: Queued writes" {
            // We have no way to get a socket in WASI from a WASI context.
            if (xev.backend == .wasi_poll) return error.SkipZigTest;
            // Windows doesn't seem to respect the SNDBUF socket option.
            if (builtin.os.tag == .windows) return error.SkipZigTest;

            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Choose random available port (Zig #14907)
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Self.init(address);

            // Bind and listen
            try server.bind(address);
            try server.listen(1);

            // Retrieve bound port and initialize client
            var sock_len = address.getOsSockLen();
            try posix.getsockname(server.fd, &address.any, &sock_len);
            const client = try Self.init(address);

            // Completions we need
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;

            // Accept
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
                    r: Self.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);
            try testing.expect(server_closed);

            // Unqueued send - Limit send buffer to 8kB, this should force partial writes.
            try posix.setsockopt(client.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 8192)));

            const send_buf = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 } ** 100_000;
            var sent_unqueued: usize = 0;

            // First we try to send the whole 1MB buffer in one write operation, this _should_ result
            // in a partial write.
            client.write(&loop, &c_connect, .{ .slice = &send_buf }, usize, &sent_unqueued, (struct {
                fn callback(
                    sent_unqueued_inner: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.WriteBuffer,
                    r: Self.WriteError!usize,
                ) xev.CallbackAction {
                    sent_unqueued_inner.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Make sure that we sent a small fraction of the buffer
            try loop.run(.until_done);
            // SO_SNDBUF doesn't seem to be respected exactly, sent_unqueued will often be ~32kB
            // even though SO_SNDBUF was set to 8kB
            try testing.expect(sent_unqueued < (send_buf.len / 10));

            // Set up queued write
            var w_queue = Self.WriteQueue{};
            var wr_send: xev.TCP.WriteRequest = undefined;
            var sent_queued: usize = 0;
            const queued_slice = send_buf[sent_unqueued..];
            client.queueWrite(&loop, &w_queue, &wr_send, .{ .slice = queued_slice }, usize, &sent_queued, (struct {
                fn callback(
                    sent_queued_inner: ?*usize,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    tcp: Self,
                    _: xev.WriteBuffer,
                    r: Self.WriteError!usize,
                ) xev.CallbackAction {
                    sent_queued_inner.?.* = r catch unreachable;

                    tcp.shutdown(l, c, void, null, (struct {
                        fn callback(
                            _: ?*void,
                            _: *xev.Loop,
                            _: *xev.Completion,
                            _: Self,
                            _: Self.ShutdownError!void,
                        ) xev.CallbackAction {
                            return .disarm;
                        }
                    }).callback);

                    return .disarm;
                }
            }).callback);

            // Set up receiver which is going to keep reading until it reads the full
            // send buffer
            const Receiver = struct {
                loop: *xev.Loop,
                conn: Self,
                completion: xev.Completion = .{},
                buf: [send_buf.len]u8 = undefined,
                bytes_read: usize = 0,

                pub fn read(receiver: *@This()) void {
                    if (receiver.bytes_read == receiver.buf.len) return;

                    const read_buf = xev.ReadBuffer{
                        .slice = receiver.buf[receiver.bytes_read..],
                    };
                    receiver.conn.read(receiver.loop, &receiver.completion, read_buf, @This(), receiver, readCb);
                }

                pub fn readCb(
                    receiver_opt: ?*@This(),
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.ReadBuffer,
                    r: Self.ReadError!usize,
                ) xev.CallbackAction {
                    var receiver = receiver_opt.?;
                    const n_bytes = r catch unreachable;

                    receiver.bytes_read += n_bytes;
                    if (receiver.bytes_read < send_buf.len) {
                        receiver.read();
                    }

                    return .disarm;
                }
            };
            var receiver = Receiver{
                .loop = &loop,
                .conn = server_conn.?,
            };
            receiver.read();

            // Wait for the send/receive
            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &send_buf, receiver.buf[0..receiver.bytes_read]);
            try testing.expect(send_buf.len == sent_unqueued + sent_queued);

            // Close
            server_conn.?.close(&loop, &c_accept, ?Self, &server_conn, (struct {
                fn callback(
                    ud: ?*?Self,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    r: Self.CloseError!void,
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
                    r: Self.CloseError!void,
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
