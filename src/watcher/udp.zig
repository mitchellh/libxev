const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const stream = @import("stream.zig");
const common = @import("common.zig");
const ThreadPool = @import("../ThreadPool.zig");

/// UDP client and server.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn UDP(comptime xev: type) type {
    if (xev.dynamic) return UDPDynamic(xev);

    return switch (xev.backend) {
        // Supported, uses sendmsg/recvmsg exclusively
        .io_uring,
        .epoll,
        => UDPSendMsg(xev),

        // Supported, uses sendto/recvfrom
        .kqueue => UDPSendto(xev),

        // Supported with tweaks
        .iocp => UDPSendtoIOCP(xev),

        // Noop
        .wasi_poll => struct {},
    };
}

/// UDP implementation that uses sendto/recvfrom.
fn UDPSendto(comptime xev: type) type {
    return struct {
        const Self = @This();

        fd: posix.socket_t,

        /// See UDPSendMsg.State
        pub const State = struct {
            userdata: ?*anyopaque,
        };

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
        });
        pub const close = S.close;
        pub const poll = S.poll;

        /// Initialize a new UDP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            return .{
                .fd = try posix.socket(
                    addr.any.family,
                    posix.SOCK.NONBLOCK | posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                    0,
                ),
            };
        }

        /// Initialize a UDP socket from a file descriptor.
        pub fn initFd(fd: posix.socket_t) Self {
            return .{
                .fd = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(self.fd, &addr.any, addr.getOsSockLen());
        }

        /// Read from the socket. This performs a single read. The callback must
        /// requeue the read if additional reads want to be performed. Additional
        /// reads simultaneously can be queued by calling this multiple times. Note
        /// that depending on the backend, the reads can happen out of order.
        pub fn read(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            buf: xev.ReadBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                addr: std.net.Address,
                s: Self,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            s.* = .{
                .userdata = userdata,
            };

            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .recvfrom = .{
                                .fd = self.fd,
                                .buffer = buf,
                            },
                        },
                        .userdata = s,
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                const s_inner = @as(?*State, @ptrCast(@alignCast(ud))).?;
                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, s_inner.userdata),
                                    l_inner,
                                    c_inner,
                                    s_inner,
                                    std.net.Address.initPosix(@alignCast(&c_inner.op.recvfrom.addr)),
                                    initFd(c_inner.op.recvfrom.fd),
                                    c_inner.op.recvfrom.buffer,
                                    r.recvfrom,
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
            s: *State,
            addr: std.net.Address,
            buf: xev.WriteBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                s: Self,
                b: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            s.* = .{
                .userdata = userdata,
            };

            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .sendto = .{
                                .fd = self.fd,
                                .buffer = buf,
                                .addr = addr,
                            },
                        },
                        .userdata = s,
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                const s_inner = @as(?*State, @ptrCast(@alignCast(ud))).?;
                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, s_inner.userdata),
                                    l_inner,
                                    c_inner,
                                    s_inner,
                                    initFd(c_inner.op.sendto.fd),
                                    c_inner.op.sendto.buffer,
                                    r.sendto,
                                });
                            }
                        }).callback,
                    };

                    loop.add(c);
                },
            }
        }

        test {
            _ = UDPTests(xev, Self);
        }
    };
}

/// UDP implementation that uses sendto/recvfrom.
fn UDPSendtoIOCP(comptime xev: type) type {
    return struct {
        const Self = @This();
        const windows = std.os.windows;

        fd: windows.HANDLE,

        /// See UDPSendMsg.State
        pub const State = struct {
            userdata: ?*anyopaque,
        };

        const S = stream.Stream(xev, Self, .{
            .close = true,
        });
        pub const close = S.close;

        /// Initialize a new UDP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            const socket = try windows.WSASocketW(addr.any.family, posix.SOCK.DGRAM, 0, null, 0, windows.ws2_32.WSA_FLAG_OVERLAPPED);

            return .{
                .fd = socket,
            };
        }

        /// Initialize a UDP socket from a file descriptor.
        pub fn initFd(fd: windows.HANDLE) Self {
            return .{
                .fd = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            const socket = @as(windows.ws2_32.SOCKET, @ptrCast(self.fd));
            try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(socket, &addr.any, addr.getOsSockLen());
        }

        /// Read from the socket. This performs a single read. The callback must
        /// requeue the read if additional reads want to be performed. Additional
        /// reads simultaneously can be queued by calling this multiple times. Note
        /// that depending on the backend, the reads can happen out of order.
        ///
        /// TODO(mitchellh): a way to receive the remote addr
        pub fn read(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            buf: xev.ReadBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                addr: std.net.Address,
                s: Self,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            s.* = .{
                .userdata = userdata,
            };

            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .recvfrom = .{
                                .fd = self.fd,
                                .buffer = buf,
                            },
                        },
                        .userdata = s,
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                const s_inner: *State = @ptrCast(@alignCast(ud.?));
                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, s_inner.userdata),
                                    l_inner,
                                    c_inner,
                                    s_inner,
                                    std.net.Address.initPosix(@alignCast(&c_inner.op.recvfrom.addr)),
                                    initFd(c_inner.op.recvfrom.fd),
                                    c_inner.op.recvfrom.buffer,
                                    r.recvfrom,
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
            s: *State,
            addr: std.net.Address,
            buf: xev.WriteBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                s: Self,
                b: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            s.* = .{
                .userdata = userdata,
            };

            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .sendto = .{
                                .fd = self.fd,
                                .buffer = buf,
                                .addr = addr,
                            },
                        },
                        .userdata = s,
                        .callback = (struct {
                            fn callback(
                                ud: ?*anyopaque,
                                l_inner: *xev.Loop,
                                c_inner: *xev.Completion,
                                r: xev.Result,
                            ) xev.CallbackAction {
                                const s_inner: *State = @ptrCast(@alignCast(ud.?));
                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, s_inner.userdata),
                                    l_inner,
                                    c_inner,
                                    s_inner,
                                    initFd(c_inner.op.sendto.fd),
                                    c_inner.op.sendto.buffer,
                                    r.sendto,
                                });
                            }
                        }).callback,
                    };

                    loop.add(c);
                },
            }
        }

        test {
            _ = UDPTests(xev, Self);
        }
    };
}

/// UDP implementation that uses sendmsg/recvmsg
fn UDPSendMsg(comptime xev: type) type {
    return struct {
        const Self = @This();

        fd: posix.socket_t,

        /// UDP requires some extra state to perform operations. The state is
        /// opaque. This isn't part of xev.Completion because it is relatively
        /// large and would force ALL operations (not just UDP) to have a relatively
        /// large structure size and we didn't want to pay that cost.
        pub const State = struct {
            userdata: ?*anyopaque = null,
            op: union {
                recv: struct {
                    buf: xev.ReadBuffer,
                    addr_buffer: std.posix.sockaddr.storage = undefined,
                    msghdr: std.posix.msghdr,
                    iov: [1]std.posix.iovec,
                },

                send: struct {
                    buf: xev.WriteBuffer,
                    addr: std.net.Address,
                    msghdr: std.posix.msghdr_const,
                    iov: [1]std.posix.iovec_const,
                },
            },
        };

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
        });
        pub const close = S.close;
        pub const poll = S.poll;

        /// Initialize a new UDP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            // On io_uring we don't use non-blocking sockets because we may
            // just get EAGAIN over and over from completions.
            const flags = flags: {
                var flags: u32 = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC;
                if (xev.backend != .io_uring) flags |= posix.SOCK.NONBLOCK;
                break :flags flags;
            };

            return .{
                .fd = try posix.socket(addr.any.family, flags, 0),
            };
        }

        /// Initialize a UDP socket from a file descriptor.
        pub fn initFd(fd: posix.socket_t) Self {
            return .{
                .fd = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(self.fd, &addr.any, addr.getOsSockLen());
        }

        /// Read from the socket. This performs a single read. The callback must
        /// requeue the read if additional reads want to be performed. Additional
        /// reads simultaneously can be queued by calling this multiple times. Note
        /// that depending on the backend, the reads can happen out of order.
        pub fn read(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            buf: xev.ReadBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                addr: std.net.Address,
                s: Self,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            s.op = .{ .recv = undefined };
            s.* = .{
                .userdata = userdata,
                .op = .{
                    .recv = .{
                        .buf = buf,
                        .msghdr = .{
                            .name = @ptrCast(&s.op.recv.addr_buffer),
                            .namelen = @sizeOf(@TypeOf(s.op.recv.addr_buffer)),
                            .iov = &s.op.recv.iov,
                            .iovlen = 1,
                            .control = null,
                            .controllen = 0,
                            .flags = 0,
                        },
                        .iov = undefined,
                    },
                },
            };

            switch (s.op.recv.buf) {
                .slice => |v| {
                    s.op.recv.iov[0] = .{
                        .base = v.ptr,
                        .len = v.len,
                    };
                },

                .array => |*arr| {
                    s.op.recv.iov[0] = .{
                        .base = arr,
                        .len = arr.len,
                    };
                },
            }

            c.* = .{
                .op = .{
                    .recvmsg = .{
                        .fd = self.fd,
                        .msghdr = &s.op.recv.msghdr,
                    },
                },

                .userdata = s,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const s_inner = @as(?*State, @ptrCast(@alignCast(ud))).?;
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, s_inner.userdata),
                            l_inner,
                            c_inner,
                            s_inner,
                            std.net.Address.initPosix(@ptrCast(&s_inner.op.recv.addr_buffer)),
                            initFd(c_inner.op.recvmsg.fd),
                            s_inner.op.recv.buf,
                            if (r.recvmsg) |v| v else |err| err,
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

        /// Write to the socket. This performs a single write. Additional writes
        /// can be queued by calling this multiple times. Note that depending on the
        /// backend, writes can happen out of order.
        pub fn write(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            addr: std.net.Address,
            buf: xev.WriteBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                s: Self,
                b: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            // Set the active field for runtime safety
            s.op = .{ .send = undefined };
            s.* = .{
                .userdata = userdata,
                .op = .{
                    .send = .{
                        .addr = addr,
                        .buf = buf,
                        .msghdr = .{
                            .name = &s.op.send.addr.any,
                            .namelen = addr.getOsSockLen(),
                            .iov = &s.op.send.iov,
                            .iovlen = 1,
                            .control = null,
                            .controllen = 0,
                            .flags = 0,
                        },
                        .iov = undefined,
                    },
                },
            };

            switch (s.op.send.buf) {
                .slice => |v| {
                    s.op.send.iov[0] = .{
                        .base = v.ptr,
                        .len = v.len,
                    };
                },

                .array => |*arr| {
                    s.op.send.iov[0] = .{
                        .base = &arr.array,
                        .len = arr.len,
                    };
                },
            }

            // On backends like epoll, you watch file descriptors for
            // specific events. Our implementation doesn't merge multiple
            // completions for a single fd, so we have to dup the fd. This
            // means we use more fds than we could optimally. This isn't a
            // problem with io_uring.

            c.* = .{
                .op = .{
                    .sendmsg = .{
                        .fd = self.fd,
                        .msghdr = &s.op.send.msghdr,
                    },
                },

                .userdata = s,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const s_inner = @as(?*State, @ptrCast(@alignCast(ud))).?;
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, s_inner.userdata),
                            l_inner,
                            c_inner,
                            s_inner,
                            initFd(c_inner.op.sendmsg.fd),
                            s_inner.op.send.buf,
                            if (r.sendmsg) |v| v else |err| err,
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

        test {
            _ = UDPTests(xev, Self);
        }
    };
}

fn UDPDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();
        const FdType = if (builtin.os.tag == .windows)
            std.os.windows.HANDLE
        else
            posix.socket_t;

        backend: Union,

        pub const Union = xev.Union(&.{"UDP"});
        pub const State = xev.Union(&.{ "UDP", "State" });

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .type = "UDP",
        });
        pub const close = S.close;
        pub const poll = S.poll;

        pub fn init(addr: std.net.Address) !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.UDP.init(addr),
                    );
                },
            } };
        }

        pub fn initFd(fdvalue: std.posix.pid_t) Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        api.UDP.initFd(fdvalue),
                    );
                },
            } };
        }

        pub fn bind(self: Self, addr: std.net.Address) !void {
            switch (xev.backend) {
                inline else => |tag| try @field(
                    self.backend,
                    @tagName(tag),
                ).bind(addr),
            }
        }

        pub fn fd(self: Self) FdType {
            switch (xev.backend) {
                inline else => |tag| return @field(
                    self.backend,
                    @tagName(tag),
                ).fd,
            }
        }

        pub fn read(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            buf: xev.ReadBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                addr: std.net.Address,
                s: Self,
                b: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            st_inner: *api.UDP.State,
                            addr_inner: std.net.Address,
                            s_inner: api.UDP,
                            b_inner: api.ReadBuffer,
                            r_inner: api.ReadError!usize,
                        ) xev.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *xev.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *xev.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                @fieldParentPtr(
                                    @tagName(tag),
                                    st_inner,
                                ),
                                addr_inner,
                                Self.initFd(s_inner.fd),
                                xev.ReadBuffer.fromBackend(tag, b_inner),
                                r_inner,
                            );
                        }
                    }).callback;

                    c.ensureTag(tag);
                    s.* = @unionInit(State, @tagName(tag), undefined);

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).read(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        &@field(s, @tagName(tag)),
                        buf.toBackend(tag),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn write(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            s: *State,
            addr: std.net.Address,
            buf: xev.WriteBuffer,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: *State,
                s: Self,
                b: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            st_inner: *api.UDP.State,
                            s_inner: api.UDP,
                            b_inner: api.WriteBuffer,
                            r_inner: api.WriteError!usize,
                        ) xev.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *xev.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *xev.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                @fieldParentPtr(
                                    @tagName(tag),
                                    st_inner,
                                ),
                                Self.initFd(s_inner.fd),
                                xev.WriteBuffer.fromBackend(tag, b_inner),
                                r_inner,
                            );
                        }
                    }).callback;

                    c.ensureTag(tag);
                    s.* = @unionInit(State, @tagName(tag), undefined);

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).write(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        &@field(s, @tagName(tag)),
                        addr,
                        buf.toBackend(tag),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = UDPTests(xev, Self);
        }
    };
}

fn UDPTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "UDP: Stream decls" {
            if (!@hasDecl(Impl, "S")) return;
            const Stream = Impl.S;
            inline for (@typeInfo(Stream).@"struct".decls) |decl| {
                const Decl = @TypeOf(@field(Stream, decl.name));
                if (Decl == void) continue;
                if (!@hasDecl(Impl, decl.name)) {
                    @compileError("missing decl: " ++ decl.name);
                }
            }
        }

        test "UDP: read/write" {
            if (builtin.os.tag == .freebsd) return error.SkipZigTest;
            const testing = std.testing;

            var tpool = ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            const address = try std.net.Address.parseIp4("127.0.0.1", 3132);
            const server = try Impl.init(address);
            const client = try Impl.init(address);

            // Bind / Recv
            try server.bind(address);
            var c_read: xev.Completion = undefined;
            var s_read: Impl.State = undefined;
            var recv_buf: [128]u8 = undefined;
            var recv_len: usize = 0;
            server.read(&loop, &c_read, &s_read, .{ .slice = &recv_buf }, usize, &recv_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: *Impl.State,
                    _: std.net.Address,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Send
            var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            var s_write: Impl.State = undefined;
            client.write(&loop, &c_write, &s_write, address, .{ .slice = &send_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: *Impl.State,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the send/receive
            try loop.run(.until_done);
            try testing.expect(recv_len > 0);
            try testing.expectEqualSlices(u8, &send_buf, recv_buf[0..recv_len]);

            // Close
            server.close(&loop, &c_read, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);
            client.close(&loop, &c_write, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
        }
    };
}
