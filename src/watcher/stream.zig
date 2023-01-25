/// Options for creating a stream type. Each of the options makes the
/// functionality available for the stream.
pub const Options = struct {
    read: bool,
    write: bool,
    close: bool,
};

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
        pub usingnamespace if (options.read) Readable(xev, T, options) else struct {};
        pub usingnamespace if (options.write) Writeable(xev, T, options) else struct {};
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
    _ = options;

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
                        .op = .{
                            .recv = .{
                                .fd = self.fd,
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
                                    T.initFd(c_inner.op.recv.fd),
                                    c_inner.op.recv.buffer,
                                    if (r.recv) |v| v else |err| err,
                                });
                            }
                        }).callback,
                    };

                    // If we're dup-ing, then we ask the backend to manage the fd.
                    switch (xev.backend) {
                        .io_uring,
                        .kqueue,
                        .wasi_poll,
                        => {},

                        .epoll => c.flags.dup = true,
                    }

                    loop.add(c);
                },
            }
        }
    };
}

pub fn Writeable(comptime xev: type, comptime T: type, comptime options: Options) type {
    _ = options;

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
                        .op = .{
                            .send = .{
                                .fd = self.fd,
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
                                    T.initFd(c_inner.op.send.fd),
                                    c_inner.op.send.buffer,
                                    if (r.send) |v| v else |err| err,
                                });
                            }
                        }).callback,
                    };

                    // If we're dup-ing, then we ask the backend to manage the fd.
                    switch (xev.backend) {
                        .io_uring,
                        .kqueue,
                        .wasi_poll,
                        => {},

                        .epoll => c.flags.dup = true,
                    }

                    loop.add(c);
                },
            }
        }
    };
}
