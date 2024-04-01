const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const common = @import("common.zig");
const queue = @import("../queue.zig");

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
                .op = .{ .close = .{ .fd = self.fd } },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const fd = T.initFd(c_inner.op.close.fd);
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            fd,
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
                                        common.userdataValue(Userdata, ud),
                                        l_inner,
                                        c_inner,
                                        T.initFd(c_inner.op.recv.fd),
                                        c_inner.op.recv.buffer,
                                        if (r.recv) |v| v else |err| err,
                                    }),

                                    .read => @call(.always_inline, cb, .{
                                        common.userdataValue(Userdata, ud),
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
                        .iocp,
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

        /// WriteQueue is the queue of write requests for ordered writes.
        /// This can be copied around.
        pub const WriteQueue = queue.Intrusive(WriteRequest);

        /// WriteRequest is a single request for a write. It wraps a
        /// completion so that it can be inserted into the WriteQueue.
        pub const WriteRequest = struct {
            completion: xev.Completion = .{},
            userdata: ?*anyopaque = null,

            /// This is the original buffer passed to queueWrite. We have
            /// to keep track of this because we may be forced to split
            /// the write or rearm the write due to partial writes, but when
            /// we call the final callback we want to pass the original
            /// complete buffer.
            full_write_buffer: xev.WriteBuffer,

            next: ?*@This() = null,

            /// This can be used to convert a completion pointer back to
            /// a WriteRequest. This is only safe of course if the completion
            /// originally is from a write request. This is useful for getting
            /// the WriteRequest back in a callback from queuedWrite.
            pub fn from(c: *xev.Completion) *WriteRequest {
                return @fieldParentPtr("completion", c);
            }
        };

        /// Write to the stream. This queues the writes to ensure they
        /// remain in order. Queueing has a small overhead: you must
        /// maintain a WriteQueue and WriteRequests instead of just
        /// Completions.
        ///
        /// If ordering isn't important, or you can maintain ordering
        /// naturally in your program, consider using write since it
        /// has a slightly smaller overhead.
        ///
        /// The "CallbackAction" return value of this callback behaves slightly
        /// different. The "rearm" return value will re-queue the same write
        /// at the end of the queue.
        ///
        /// It is safe to call this at anytime from the main thread.
        pub fn queueWrite(
            self: Self,
            loop: *xev.Loop,
            q: *WriteQueue,
            req: *WriteRequest,
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
            // Initialize our completion
            req.* = .{ .full_write_buffer = buf };
            // Must be kept in sync with partial write logic inside the callback
            self.write_init(&req.completion, buf);
            req.completion.userdata = q;
            req.completion.callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const q_inner = @as(?*WriteQueue, @ptrCast(@alignCast(ud))).?;

                    // The queue MUST have a request because a completion
                    // can only be added if the queue is not empty, and
                    // nothing else should be popping!.
                    //
                    // We only peek the request here (not pop) because we may
                    // need to rearm this write if the write was partial.
                    const req_inner: *WriteRequest = q_inner.head.?;

                    const cb_res = write_result(c_inner, r);
                    var result: WriteError!usize = cb_res.result;

                    // Checks whether the entire buffer was written, this is
                    // necessary to guarantee correct ordering of writes.
                    // If the write was partial, it re-submits the remainder of
                    // the buffer.
                    const queued_len = writeBufferLength(cb_res.buf);
                    if (cb_res.result) |written_len| {
                        if (written_len < queued_len) {
                            // Write remainder of the buffer, reusing the same completion
                            const rem_buf = writeBufferRemainder(cb_res.buf, written_len);
                            cb_res.writer.write_init(&req_inner.completion, rem_buf);
                            req_inner.completion.userdata = q_inner;
                            req_inner.completion.callback = callback;
                            l_inner.add(&req_inner.completion);
                            return .disarm;
                        }

                        // We wrote the entire buffer, modify the result to indicate
                        // to the caller that all bytes have been written.
                        result = writeBufferLength(req_inner.full_write_buffer);
                    } else |_| {}

                    // We can pop previously peeked request.
                    _ = q_inner.pop().?;

                    const action = @call(.always_inline, cb, .{
                        common.userdataValue(Userdata, req_inner.userdata),
                        l_inner,
                        c_inner,
                        cb_res.writer,
                        req_inner.full_write_buffer,
                        result,
                    });

                    // Rearm requeues this request, it doesn't return rearm
                    // on the actual callback here...
                    if (action == .rearm) q_inner.push(req_inner);

                    // If we have another request, add that completion next.
                    if (q_inner.head) |req_next| l_inner.add(&req_next.completion);

                    // We always disarm because the completion in the next
                    // request will be used if there is more to queue.
                    return .disarm;
                }
            }).callback;

            // The userdata as to go on the WriteRequest because we need
            // our actual completion userdata to be the WriteQueue so that
            // we can process the queue.
            req.userdata = @as(?*anyopaque, @ptrCast(@alignCast(userdata)));

            // If the queue is empty, then we add our completion. Otherwise,
            // the previously queued writes will trigger this one.
            if (q.empty()) loop.add(&req.completion);

            // We always add this item to our queue no matter what
            q.push(req);
        }

        /// Write to the stream. This performs a single write. Additional
        /// writes can be requested by calling this multiple times.
        ///
        /// IMPORTANT: writes are NOT queued. There is no order guarantee
        /// if this is called multiple times. If ordered writes are important
        /// (they usually are!) then you should only call write again once
        /// the previous write callback is called.
        ///
        /// If ordering is important, use queueWrite instead.
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
            self.write_init(c, buf);
            c.userdata = userdata;
            c.callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const cb_res = write_result(c_inner, r);
                    return @call(.always_inline, cb, .{
                        common.userdataValue(Userdata, ud),
                        l_inner,
                        c_inner,
                        cb_res.writer,
                        cb_res.buf,
                        cb_res.result,
                    });
                }
            }).callback;

            loop.add(c);
        }

        /// Extracts the result from a completion for a write callback.
        inline fn write_result(c: *xev.Completion, r: xev.Result) struct {
            writer: Self,
            buf: xev.WriteBuffer,
            result: WriteError!usize,
        } {
            return switch (options.write) {
                .none => unreachable,

                .send => .{
                    .writer = T.initFd(c.op.send.fd),
                    .buf = c.op.send.buffer,
                    .result = if (r.send) |v| v else |err| err,
                },

                .write => .{
                    .writer = T.initFd(c.op.write.fd),
                    .buf = c.op.write.buffer,
                    .result = if (r.write) |v| v else |err| err,
                },
            };
        }

        /// Initialize the completion c for a write. This does NOT set
        /// userdata or a callback.
        fn write_init(
            self: Self,
            c: *xev.Completion,
            buf: xev.WriteBuffer,
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
                    };

                    // If we're dup-ing, then we ask the backend to manage the fd.
                    switch (xev.backend) {
                        .io_uring,
                        .wasi_poll,
                        .iocp,
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
                },
            }
        }

        /// Returns the length of the write buffer
        fn writeBufferLength(buf: xev.WriteBuffer) usize {
            return switch (buf) {
                .slice => |slice| slice.len,
                .array => |array| array.len,
            };
        }

        /// Given a `WriteBuffer` and number of bytes written during the previous
        /// write operation, returns a new `WriteBuffer` with remaining data.
        fn writeBufferRemainder(buf: xev.WriteBuffer, offset: usize) xev.WriteBuffer {
            switch (buf) {
                .slice => |slice| {
                    assert(offset <= slice.len);
                    return .{ .slice = slice[offset..] };
                },
                .array => |array| {
                    assert(offset <= array.len);
                    const rem_len = array.len - offset;
                    var wb = xev.WriteBuffer{ .array = .{
                        .array = undefined,
                        .len = rem_len,
                    } };
                    @memcpy(
                        wb.array.array[0..rem_len],
                        array.array[offset..][0..rem_len],
                    );
                    return wb;
                },
            }
        }
    };
}

/// Creates a generic stream type that supports read, write, close. This
/// can be used for any file descriptor that would exhibit normal blocking
/// behavior on read/write. This should NOT be used for local files because
/// local files have some special properties; you should use xev.File for that.
pub fn GenericStream(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The underlying file
        fd: std.posix.fd_t,

        pub usingnamespace Stream(xev, Self, .{
            .close = true,
            .read = .read,
            .write = .write,
        });

        /// Initialize a generic stream from a file descriptor.
        pub fn initFd(fd: std.posix.fd_t) Self {
            return .{
                .fd = fd,
            };
        }

        /// Clean up any watcher resources. This does NOT close the file.
        /// If you want to close the file you must call close or do so
        /// synchronously.
        pub fn deinit(self: *const Self) void {
            _ = self;
        }

        test "pty: child to parent" {
            const testing = std.testing;
            switch (builtin.os.tag) {
                .linux, .macos => {},
                else => return error.SkipZigTest,
            }

            // Create the pty parent/child side.
            var pty = try Pty.init();
            defer pty.deinit();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            const parent = initFd(pty.parent);
            const child = initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            parent.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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

            // This should not block!
            try loop.run(.no_wait);
            try testing.expect(read_len == null);

            // Send
            const send_buf = "hello, world!";
            var c_write: xev.Completion = undefined;
            child.write(&loop, &c_write, .{ .slice = send_buf }, void, null, (struct {
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

            // The write and read should trigger
            try loop.run(.until_done);
            try testing.expect(read_len != null);
            try testing.expectEqualSlices(u8, send_buf, read_buf[0..read_len.?]);
        }

        test "pty: parent to child" {
            const testing = std.testing;
            switch (builtin.os.tag) {
                .linux, .macos => {},
                else => return error.SkipZigTest,
            }

            // Create the pty parent/child side.
            var pty = try Pty.init();
            defer pty.deinit();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            const parent = initFd(pty.parent);
            const child = initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            child.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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

            // This should not block!
            try loop.run(.no_wait);
            try testing.expect(read_len == null);

            // Send (note the newline at the end of the buf is important
            // since we're in cooked mode)
            const send_buf = "hello, world!\n";
            var c_write: xev.Completion = undefined;
            parent.write(&loop, &c_write, .{ .slice = send_buf }, void, null, (struct {
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

            // The write and read should trigger
            try loop.run(.until_done);
            try testing.expect(read_len != null);
            try testing.expectEqualSlices(u8, send_buf, read_buf[0..read_len.?]);
        }

        test "pty: queued writes" {
            const testing = std.testing;
            switch (builtin.os.tag) {
                .linux, .macos => {},
                else => return error.SkipZigTest,
            }

            // Create the pty parent/child side.
            var pty = try Pty.init();
            defer pty.deinit();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            const parent = initFd(pty.parent);
            const child = initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            child.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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

            // This should not block!
            try loop.run(.no_wait);
            try testing.expect(read_len == null);

            var write_queue: Self.WriteQueue = .{};
            var write_req: [2]Self.WriteRequest = undefined;

            // Send (note the newline at the end of the buf is important
            // since we're in cooked mode)
            parent.queueWrite(
                &loop,
                &write_queue,
                &write_req[0],
                .{ .slice = "hello, " },
                void,
                null,
                (struct {
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
                }).callback,
            );

            var c_result: ?*xev.Completion = null;
            parent.queueWrite(
                &loop,
                &write_queue,
                &write_req[1],
                .{ .slice = "world!\n" },
                ?*xev.Completion,
                &c_result,
                (struct {
                    fn callback(
                        ud: ?*?*xev.Completion,
                        _: *xev.Loop,
                        c: *xev.Completion,
                        _: Self,
                        _: xev.WriteBuffer,
                        r: Self.WriteError!usize,
                    ) xev.CallbackAction {
                        _ = r catch unreachable;
                        ud.?.* = c;
                        return .disarm;
                    }
                }).callback,
            );

            // The write and read should trigger
            try loop.run(.until_done);
            try testing.expect(read_len != null);
            try testing.expectEqualSlices(u8, "hello, world!\n", read_buf[0..read_len.?]);

            // Verify our completion is equal to our request
            try testing.expect(Self.WriteRequest.from(c_result.?) == &write_req[1]);
        }
    };
}

/// Helper to open a pty. This isn't exposed as a public API this is only
/// used for tests.
const Pty = struct {
    /// The file descriptors for the parent/child side of the pty. This refers
    /// to the master/slave side respectively, and while that terminology is
    /// the officially used terminology of the syscall, I will use parent/child
    /// here.
    parent: std.posix.fd_t,
    child: std.posix.fd_t,

    /// Redeclare this winsize struct so we can just use a Zig struct. This
    /// layout should be correct on all tested platforms.
    const Winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    // libc pty.h
    extern "c" fn openpty(
        parent: *std.posix.fd_t,
        child: *std.posix.fd_t,
        name: ?[*]u8,
        termios: ?*const anyopaque, // termios but we don't use it
        winsize: ?*const Winsize,
    ) c_int;

    pub fn init() !Pty {
        // Reasonable size
        var size: Winsize = .{
            .ws_row = 80,
            .ws_col = 80,
            .ws_xpixel = 800,
            .ws_ypixel = 600,
        };

        var parent_fd: std.posix.fd_t = undefined;
        var child_fd: std.posix.fd_t = undefined;
        if (openpty(
            &parent_fd,
            &child_fd,
            null,
            null,
            &size,
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = std.posix.system.close(parent_fd);
            _ = std.posix.system.close(child_fd);
        }

        return .{
            .parent = parent_fd,
            .child = child_fd,
        };
    }

    pub fn deinit(self: *Pty) void {
        std.posix.close(self.parent);
        std.posix.close(self.child);
    }
};
