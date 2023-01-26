const std = @import("std");

/// Options for creating a stream type. Each of the options makes the
/// functionality available for the stream.
pub const Options = struct {
    read: ReadMethod,
    write: WriteMethod,
    close: bool,

    /// True to schedule the read/write on the threadpool.
    threadpool: bool = false,

    pub const ReadMethod = enum { none, read, recv };
    pub const WriteMethod = enum { none, write, send };
};

/// Creates a generic stream type that supports read, write, close. This
/// can be used for any file descriptor that would exhibit normal blocking
/// behavior on read/write. This should NOT be used for local files because
/// local files have some special properties; you should use xev.File for that.
pub fn GenericStream(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The underlying file
        fd: std.os.fd_t,

        pub usingnamespace Stream(xev, Self, .{
            .close = true,
            .read = .read,
            .write = .write,
        });

        /// Initialize a generic stream from a file descriptor.
        pub fn initFd(fd: std.os.fd_t) Self {
            return .{
                .fd = fd,
            };
        }

        /// Clean up any watcher resources. This does NOT close the file.
        /// If you want to close the file you must call close or do so
        /// synchronously.
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

/// Creates a stream type that is meant to be embedded within other
/// types using "usingnamespace". A stream is something that supports read,
/// write, close, etc. The exact operations supported are defined by the
/// "options" struct.
///
/// T requirements:
///   - field named "fd" of type fd_t or socket_t
///   - decl named "initFd" to initialize a new T from a fd
///
pub fn Stream(comptime xev: type, comptime T: type, comptime options: Options) type {
    return struct {
        pub usingnamespace if (options.close) Closeable(xev, T, options) else struct {};
        pub usingnamespace if (options.read != .none) Readable(xev, T, options) else struct {};
        pub usingnamespace if (options.write != .none) Writeable(xev, T, options) else struct {};
    };
}

pub fn Closeable(comptime xev: type, comptime T: type, comptime options: Options) type {
    _ = options;

    return struct {
        const Self = T;

        pub const CloseError = xev.CloseError;

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
                        .fd = self.fd,
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
                            T.initFd(c_inner.op.close.fd),
                            if (r.close) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }
    };
}

pub fn Readable(comptime xev: type, comptime T: type, comptime options: Options) type {
    return struct {
        const Self = T;

        pub const ReadError = xev.ReadError;

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
                        .op = switch (options.read) {
                            .none => unreachable,

                            .read => .{
                                .read = .{
                                    .fd = self.fd,
                                    .buffer = buf,
                                },
                            },

                            .recv => .{
                                .recv = .{
                                    .fd = self.fd,
                                    .buffer = buf,
                                },
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
                                return switch (options.read) {
                                    .none => unreachable,

                                    .recv => @call(.always_inline, cb, .{
                                        @ptrCast(?*Userdata, @alignCast(
                                            @max(1, @alignOf(Userdata)),
                                            ud,
                                        )),
                                        l_inner,
                                        c_inner,
                                        T.initFd(c_inner.op.recv.fd),
                                        c_inner.op.recv.buffer,
                                        if (r.recv) |v| v else |err| err,
                                    }),

                                    .read => @call(.always_inline, cb, .{
                                        @ptrCast(?*Userdata, @alignCast(
                                            @max(1, @alignOf(Userdata)),
                                            ud,
                                        )),
                                        l_inner,
                                        c_inner,
                                        T.initFd(c_inner.op.read.fd),
                                        c_inner.op.read.buffer,
                                        if (r.read) |v| v else |err| err,
                                    }),
                                };
                            }
                        }).callback,
                    };

                    // If we're dup-ing, then we ask the backend to manage the fd.
                    switch (xev.backend) {
                        .io_uring,
                        .wasi_poll,
                        => {},

                        .epoll => {
                            if (options.threadpool)
                                c.flags.threadpool = true
                            else
                                c.flags.dup = true;
                        },

                        .kqueue => {
                            if (options.threadpool) c.flags.threadpool = true;
                        },
                    }

                    loop.add(c);
                },
            }
        }
    };
}

pub fn Writeable(comptime xev: type, comptime T: type, comptime options: Options) type {
    return struct {
        const Self = T;

        pub const WriteError = xev.WriteError;

        /// Write to the stream. This performs a single write. Additional
        /// writes can be requested by calling this multiple times.
        ///
        /// IMPORTANT: writes are NOT queued. There is no order guarantee
        /// if this is called multiple times. If ordered writes are important
        /// (they usually are!) then you should only call write again once
        /// the previous write callback is called.
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
                        .op = switch (options.write) {
                            .none => unreachable,

                            .write => .{
                                .write = .{
                                    .fd = self.fd,
                                    .buffer = buf,
                                },
                            },

                            .send => .{
                                .send = .{
                                    .fd = self.fd,
                                    .buffer = buf,
                                },
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
                                return switch (options.write) {
                                    .none => unreachable,

                                    .send => @call(.always_inline, cb, .{
                                        @ptrCast(?*Userdata, @alignCast(
                                            @max(1, @alignOf(Userdata)),
                                            ud,
                                        )),
                                        l_inner,
                                        c_inner,
                                        T.initFd(c_inner.op.send.fd),
                                        c_inner.op.send.buffer,
                                        if (r.send) |v| v else |err| err,
                                    }),

                                    .write => @call(.always_inline, cb, .{
                                        @ptrCast(?*Userdata, @alignCast(
                                            @max(1, @alignOf(Userdata)),
                                            ud,
                                        )),
                                        l_inner,
                                        c_inner,
                                        T.initFd(c_inner.op.write.fd),
                                        c_inner.op.write.buffer,
                                        if (r.write) |v| v else |err| err,
                                    }),
                                };
                            }
                        }).callback,
                    };

                    // If we're dup-ing, then we ask the backend to manage the fd.
                    switch (xev.backend) {
                        .io_uring,
                        .wasi_poll,
                        => {},

                        .epoll => {
                            if (options.threadpool) {
                                c.flags.threadpool = true;
                            } else {
                                c.flags.dup = true;
                            }
                        },

                        .kqueue => {
                            if (options.threadpool) c.flags.threadpool = true;
                        },
                    }

                    loop.add(c);
                },
            }
        }
    };
}
