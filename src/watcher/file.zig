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
    if (xev.dynamic) return FileDynamic(xev);
    return FileStream(xev);
}

/// An implementation of File that uses the stream abstractions.
fn FileStream(comptime xev: type) type {
    return struct {
        const Self = @This();
        const FdType = if (xev.backend == .iocp) std.os.windows.HANDLE else posix.socket_t;

        /// The underlying file
        fd: FdType,

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .read = .read,
            .write = .write,
            .threadpool = true,
        });
        pub const close = S.close;
        pub const poll = S.poll;
        pub const read = S.read;
        pub const write = S.write;
        pub const writeInit = S.writeInit;
        pub const queueWrite = S.queueWrite;

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
        pub fn deinit(self: *const Self) void {
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
                r: xev.ReadError!usize,
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

                        .kqueue => kqueue: {
                            // If we're not reading any actual data, we don't
                            // need a threadpool since only read() is blocking.
                            switch (buf) {
                                .array => {},
                                .slice => |v| if (v.len == 0) break :kqueue {},
                            }

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
            q: *xev.WriteQueue,
            req: *xev.WriteRequest,
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
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            // Initialize our completion
            req.* = .{};
            self.pwriteInit(&req.completion, buf, offset);
            req.completion.userdata = q;
            req.completion.callback = (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    const q_inner = @as(?*xev.WriteQueue, @ptrCast(@alignCast(ud))).?;

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
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            self.pwriteInit(c, buf, offset);
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
            result: xev.WriteError!usize,
        } {
            return .{
                .writer = Self.initFd(c.op.pwrite.fd),
                .buf = c.op.pwrite.buffer,
                .result = if (r.pwrite) |v| v else |err| err,
            };
        }

        fn pwriteInit(
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

        test {
            _ = FileTests(xev, Self);
        }
    };
}

fn FileDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"File"});

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .read = .read,
            .write = .write,
            .threadpool = true,
            .type = "File",
        });
        pub const close = S.close;
        pub const poll = S.poll;
        pub const read = S.read;
        pub const write = S.write;
        pub const queueWrite = S.queueWrite;

        pub fn init(file: std.fs.File) !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.File.init(file),
                    );
                },
            } };
        }

        pub fn initFd(fd: std.posix.pid_t) Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        api.File.initFd(fd),
                    );
                },
            } };
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
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: api.File,
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
                                Self.initFd(s_inner.fd),
                                xev.WriteBuffer.fromBackend(tag, b_inner),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).pwrite(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        buf.toBackend(tag),
                        offset,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
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
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: api.File,
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
                                Self.initFd(s_inner.fd),
                                xev.ReadBuffer.fromBackend(tag, b_inner),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).pread(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        buf.toBackend(tag),
                        offset,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = FileTests(xev, Self);
        }
    };
}

fn FileTests(
    comptime xev: type,
    comptime Impl: type,
) type {
    return struct {
        test "File: Stream decls" {
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

        test "kqueue: zero-length read for readiness" {
            if (builtin.os.tag != .macos) return error.SkipZigTest;

            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Create our pipe and write to it so its ready to be read
            const pipe = try posix.pipe2(.{ .CLOEXEC = true });
            defer posix.close(pipe[1]);
            _ = try posix.write(pipe[1], "x");

            // Create our file
            const file = Impl.initFd(pipe[0]);

            var c: xev.Completion = undefined;

            // Read
            var ready: bool = false;
            file.read(&loop, &c, .{ .slice = &.{} }, bool, &ready, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(ready);
        }

        test "poll" {
            if (builtin.os.tag == .wasi) return error.SkipZigTest;
            if (builtin.os.tag == .windows) return error.SkipZigTest;

            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            // Create our pipe and write to it so its ready to be read
            const pipe = try posix.pipe2(.{ .CLOEXEC = true });
            defer posix.close(pipe[1]);
            _ = try posix.write(pipe[1], "x");

            // Create our file
            const file = Impl.initFd(pipe[0]);

            var c: xev.Completion = undefined;

            // Poll read
            var ready: bool = false;
            file.poll(&loop, &c, .read, bool, &ready, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.PollError!xev.PollEvent,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(ready);
        }

        test "read/write" {
            // wasi: local files don't work with poll (always ready)
            if (builtin.os.tag == .wasi) return error.SkipZigTest;
            // windows: std.fs.File is not opened with OVERLAPPED flag.
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            if (builtin.os.tag == .freebsd) return error.SkipZigTest;

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

            const file = try Impl.init(f);

            // Perform a write and then a read
            var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            file.write(&loop, &c_write, .{ .slice = &write_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
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
            const file2 = try Impl.init(f2);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            file2.read(&loop, &c_write, .{ .slice = &read_buf }, usize, &read_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
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
            if (builtin.os.tag == .freebsd) return error.SkipZigTest;

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

            const file = try Impl.init(f);

            // Perform a write and then a read
            var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            var c_write: xev.Completion = undefined;
            file.pwrite(&loop, &c_write, .{ .slice = &write_buf }, 0, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
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
            const file2 = try Impl.init(f2);

            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            file2.pread(&loop, &c_write, .{ .slice = &read_buf }, 0, usize, &read_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
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
            if (builtin.os.tag == .freebsd) return error.SkipZigTest;

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

            const file = try Impl.init(f);
            var write_queue: xev.WriteQueue = .{};
            var write_req: [2]xev.WriteRequest = undefined;

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
                        _: Impl,
                        _: xev.WriteBuffer,
                        r: xev.WriteError!usize,
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
                        _: Impl,
                        _: xev.WriteBuffer,
                        r: xev.WriteError!usize,
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
            const file2 = try Impl.init(f2);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: usize = 0;
            var c_read: xev.Completion = undefined;
            file2.read(&loop, &c_read, .{ .slice = &read_buf }, usize, &read_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
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
