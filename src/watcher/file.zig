const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const assert = std.debug.assert;
const posix = std.posix;
const main = @import("../main.zig");
const stream = @import("stream.zig");

/// File operations.
///
/// These operations typically run on the event loop thread pool, rather
/// than the core async OS APIs, because most core async OS APIs don't support
/// async operations on regular files (with many caveats attached to that
/// statement). This high-level abstraction will attempt to make the right
/// decision about what to do but this should generally be used by
/// operations that need to run on a thread pool. For operations that you're
/// sure are better supported by core async OS APIs (such as sockets, pipes,
/// TTYs, etc.), use a specific high-level abstraction like xev.TCP or
/// the generic xev.Stream.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn File(comptime xev: type) type {
    return struct {
        const Self = @This();
        const FdType = if (xev.backend == .iocp) std.windows.HANDLE else posix.socket_t;

        /// The underlying file
        fd: FdType,

        pub usingnamespace stream.Stream(xev, Self, .{
            .close = true,
            .read = .read,
            .write = .write,
            .threadpool = true,
        });

        /// Initialize a File from a std.fs.File.
        pub fn init(file: std.fs.File) !Self {
            return .{
                .fd = file.handle,
            };
        }

        /// Initialize a File from a file descriptor.
        pub fn initFd(fd: std.fs.File.Handle) Self {
            return .{
                .fd = fd,
            };
        }

        /// Clean up any watcher resources. This does NOT close the file.
        /// If you want to close the file you must call close or do so
        /// synchronously.
        pub fn deinit(self: *const File) void {
            _ = self;
        }

        pub fn pread(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            buf: xev.ReadBuffer,
            offset: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                b: xev.ReadBuffer,
                r: Self.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .pread = .{
                                .fd = self.fd,
                                .buffer = buf,
                                .offset = offset,
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
                                    Self.initFd(c_inner.op.pread.fd),
                                    c_inner.op.pread.buffer,
                                    if (r.pread) |v| v else |err| err,
                                });
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
                            c.flags.threadpool = true;
                        },

                        .kqueue => {
                            c.flags.threadpool = true;
                        },
                    }

                    loop.add(c);
                },
            }
        }

        pub fn queuePWrite(
            self: Self,
            loop: *xev.Loop,
            q: *Self.WriteQueue,
            req: *Self.WriteRequest,
            buf: xev.WriteBuffer,
            offset: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                b: xev.WriteBuffer,
                r: Self.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            // Initialize our completion
            req.* = .{};
            self.pwrite_init(&req.completion, buf, offset);
            req.completion.userdata = q;
            req.completion.callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const q_inner = @as(?*Self.WriteQueue, @ptrCast(@alignCast(ud))).?;

                    // The queue MUST have a request because a completion
                    // can only be added if the queue is not empty, and
                    // nothing else should be popping!.
                    const req_inner = q_inner.pop().?;

                    const cb_res = pwrite_result(c_inner, r);
                    const action = @call(.always_inline, cb, .{
                        common.userdataValue(Userdata, req_inner.userdata),
                        l_inner,
                        c_inner,
                        cb_res.writer,
                        cb_res.buf,
                        cb_res.result,
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

        pub fn pwrite(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            buf: xev.WriteBuffer,
            offset: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                b: xev.WriteBuffer,
                r: Self.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            self.pwrite_init(c, buf, offset);
            c.userdata = userdata;
            c.callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const cb_res = pwrite_result(c_inner, r);
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

        inline fn pwrite_result(c: *xev.Completion, r: xev.Result) struct {
            writer: Self,
            buf: xev.WriteBuffer,
            result: Self.WriteError!usize,
        } {
            return .{
                .writer = Self.initFd(c.op.pwrite.fd),
                .buf = c.op.pwrite.buffer,
                .result = if (r.pwrite) |v| v else |err| err,
            };
        }

        fn pwrite_init(
            self: Self,
            c: *xev.Completion,
            buf: xev.WriteBuffer,
            offset: u64,
        ) void {
            switch (buf) {
                inline .slice, .array => {
                    c.* = .{
                        .op = .{
                            .pwrite = .{
                                .fd = self.fd,
                                .buffer = buf,
                                .offset = offset,
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
                            c.flags.threadpool = true;
                        },

                        .kqueue => {
                            c.flags.threadpool = true;
                        },
                    }
                },
            }
        }

        test "read/write" {
            // wasi: local files don't work with poll (always ready)
            if (builtin.os.tag == .wasi) return error.SkipZigTest;
            // windows: std.fs.File is not opened with OVERLAPPED flag.
            if (builtin.os.tag == .windows) return error.SkipZigTest;

            const testing = std.testing;

            var tpool = main.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create our file
            const path = "test_watcher_file";
            const f = try std.fs.cwd().createFile(path, .{
                .read = true,
                .truncate = true,
            });
            defer f.close();
            defer std.fs.cwd().deleteFile(path) catch {};

            const file = try init(f);

            // Perform a write and then a read
            var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            file.write(&loop, &c_write, .{ .slice = &write_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.WriteBuffer,
                    r: Self.WriteError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the write
            try loop.run(.until_done);

            // Make sure the data is on disk
            try f.sync();

            const f2 = try std.fs.cwd().openFile(path, .{});
            defer f2.close();
            const file2 = try init(f2);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            file2.read(&loop, &c_write, .{ .slice = &read_buf }, usize, &read_len, (struct {
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

            try loop.run(.until_done);
            try testing.expectEqual(read_len, write_buf.len);
            try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
        }

        test "pread/pwrite" {
            // wasi: local files don't work with poll (always ready)
            if (builtin.os.tag == .wasi) return error.SkipZigTest;
            // windows: std.fs.File is not opened with OVERLAPPED flag.
            if (builtin.os.tag == .windows) return error.SkipZigTest;

            const testing = std.testing;

            var tpool = main.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create our file
            const path = "test_watcher_file";
            const f = try std.fs.cwd().createFile(path, .{
                .read = true,
                .truncate = true,
            });
            defer f.close();
            defer std.fs.cwd().deleteFile(path) catch {};

            const file = try init(f);

            // Perform a write and then a read
            var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            file.pwrite(&loop, &c_write, .{ .slice = &write_buf }, 0, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Self,
                    _: xev.WriteBuffer,
                    r: Self.WriteError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the write
            try loop.run(.until_done);

            // Make sure the data is on disk
            try f.sync();

            const f2 = try std.fs.cwd().openFile(path, .{});
            defer f2.close();
            const file2 = try init(f2);

            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            file2.pread(&loop, &c_write, .{ .slice = &read_buf }, 0, usize, &read_len, (struct {
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

            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
        }

        test "queued writes" {
            // wasi: local files don't work with poll (always ready)
            if (builtin.os.tag == .wasi) return error.SkipZigTest;
            // windows: std.fs.File is not opened with OVERLAPPED flag.
            if (builtin.os.tag == .windows) return error.SkipZigTest;

            const testing = std.testing;

            var tpool = main.ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create our file
            const path = "test_watcher_file";
            const f = try std.fs.cwd().createFile(path, .{
                .read = true,
                .truncate = true,
            });
            defer f.close();
            defer std.fs.cwd().deleteFile(path) catch {};

            const file = try init(f);
            var write_queue: Self.WriteQueue = .{};
            var write_req: [2]Self.WriteRequest = undefined;

            // Perform a write and then a read
            file.queueWrite(
                &loop,
                &write_queue,
                &write_req[0],
                .{ .slice = "1234" },
                void,
                null,
                (struct {
                    fn callback(
                        _: ?*void,
                        _: *xev.Loop,
                        _: *xev.Completion,
                        _: Self,
                        _: xev.WriteBuffer,
                        r: Self.WriteError!usize,
                    ) xev.CallbackAction {
                        _ = r catch unreachable;
                        return .disarm;
                    }
                }).callback,
            );
            file.queueWrite(
                &loop,
                &write_queue,
                &write_req[1],
                .{ .slice = "5678" },
                void,
                null,
                (struct {
                    fn callback(
                        _: ?*void,
                        _: *xev.Loop,
                        _: *xev.Completion,
                        _: Self,
                        _: xev.WriteBuffer,
                        r: Self.WriteError!usize,
                    ) xev.CallbackAction {
                        _ = r catch unreachable;
                        return .disarm;
                    }
                }).callback,
            );

            // Wait for the write
            try loop.run(.until_done);

            // Make sure the data is on disk
            try f.sync();

            const f2 = try std.fs.cwd().openFile(path, .{});
            defer f2.close();
            const file2 = try init(f2);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            var c_read: xev.Completion = undefined;
            file2.read(&loop, &c_read, .{ .slice = &read_buf }, usize, &read_len, (struct {
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

            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, "12345678", read_buf[0..read_len]);
        }
    };
}
