const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const common = @import("common.zig");
const queue = @import("../queue.zig");

/// Options for creating a stream type. Each of the options makes the
/// functionality available for the stream.
pub const Options = struct {
    read: ReadMethod = .none,
    write: WriteMethod = .none,
    close: bool = false,
    poll: bool = false,

    /// True to schedule the read/write on the threadpool.
    threadpool: bool = false,

    /// Set to non-null for dynamic APIs so we can know what our
    /// parent type name is.
    type: ?[]const u8 = null,

    pub const ReadMethod = enum { none, read, recv };
    pub const WriteMethod = enum { none, write, send };
};

/// Returns the shared decls for all streams that should be set for
/// the xev type.
pub fn Shared(comptime xev: type) type {
    return struct {
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

        /// Errors that can be returned from polling.
        pub const PollError = switch (xev.backend) {
            .io_uring,
            .epoll,
            => xev.Sys.PollError,

            .kqueue,
            => xev.ReadError,

            .iocp,
            .wasi_poll,
            => error{},
        };

        /// Events that can be polled for using the high level streams.
        pub const PollEvent = enum(u32) {
            read = switch (xev.backend) {
                .io_uring => std.posix.POLL.IN,
                .epoll => std.os.linux.EPOLL.IN,
                .kqueue => 0, // doesn't matter
                .iocp, .wasi_poll => 0, // invalid
            },

            fn fromResult(
                c: *const xev.Completion,
                result: xev.Result,
            ) PollError!PollEvent {
                return switch (xev.backend) {
                    .io_uring,
                    .epoll,
                    => if (result.poll) |_|
                        @enumFromInt(c.op.poll.events)
                    else |err|
                        err,

                    .kqueue => switch (c.op) {
                        .read, .recv => .read,
                        else => unreachable,
                    },

                    .iocp,
                    .wasi_poll,
                    => @compileError("poll not supported on this backend"),
                };
            }
        };
    };
}

/// Creates a stream type that is meant to be embedded within other types.
/// A stream is something that supports read, write, close, etc. The exact
/// operations supported are defined by the "options" struct.
///
/// T requirements:
///   - field named "fd" of type fd_t or socket_t
///   - decl named "initFd" to initialize a new T from a fd
///
pub fn Stream(comptime xev: type, comptime T: type, comptime options: Options) type {
    return struct {
        const C_: ?type = if (options.close) Closeable(xev, T, options) else null;
        pub const close = if (C_) |C| C.close else {};

        const P_: ?type = if (options.poll) Pollable(xev, T, options) else null;
        pub const poll = if (P_) |P| poll: {
            if (!@hasDecl(P, "poll")) break :poll {};
            break :poll P.poll;
        } else {};

        const R_: ?type = if (options.read != .none) Readable(xev, T, options) else null;
        pub const read = if (R_) |R| R.read else {};

        const W_: ?type = if (options.write != .none) Writeable(xev, T, options) else null;
        pub const writeInit = if (W_) |W| writeInit: {
            if (xev.dynamic) break :writeInit {};
            break :writeInit W.writeInit;
        } else {};
        pub const write = if (W_) |W| W.write else null;
        pub const queueWrite = if (W_) |W| W.queueWrite else {};
    };
}

fn Pollable(comptime xev: type, comptime T: type, comptime options: Options) type {
    if (xev.dynamic) {
        // If all candidate backends do not support poll, our dynamic
        // type cannot support poll.
        comptime {
            for (xev.candidates) |be| {
                const CandidateT = @field(be.Api(), options.type.?);
                const info = @typeInfo(CandidateT).@"struct";
                for (info.decls) |decl| {
                    if (std.mem.eql(u8, decl.name, "poll")) break;
                } else return struct {};
            }
        }

        return struct {
            const Self = T;

            pub fn poll(
                self: Self,
                loop: *xev.Loop,
                c: *xev.Completion,
                event: xev.PollEvent,
                comptime Userdata: type,
                userdata: ?*Userdata,
                comptime cb: *const fn (
                    ud: ?*Userdata,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: Self,
                    r: xev.PollError!xev.PollEvent,
                ) xev.CallbackAction,
            ) void {
                switch (xev.backend) {
                    inline else => |tag| {
                        c.ensureTag(tag);

                        const api = (comptime xev.superset(tag)).Api();
                        const BackendSelf = @field(api, options.type.?);
                        const api_cb = (struct {
                            fn callback(
                                ud_inner: ?*Userdata,
                                l_inner: *api.Loop,
                                c_inner: *api.Completion,
                                s_inner: BackendSelf,
                                r_inner: api.PollError!api.PollEvent,
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
                                    if (r_inner) |v|
                                        xev.PollEvent.fromBackend(tag, v)
                                    else |err|
                                        err,
                                );
                            }
                        }).callback;

                        @field(
                            self.backend,
                            @tagName(tag),
                        ).poll(
                            &@field(loop.backend, @tagName(tag)),
                            &@field(c.value, @tagName(tag)),
                            event.toBackend(tag),
                            Userdata,
                            userdata,
                            api_cb,
                        );
                    },
                }
            }
        };
    }

    // Do not add the methods for poll if the backend doesn't support it.
    switch (xev.backend) {
        .io_uring, .epoll, .kqueue => {},
        .iocp, .wasi_poll => return struct {},
    }

    return struct {
        const Self = T;

        /// Poll the file descriptor for the given event. The high-level
        /// abstraction only allows a single event to be polled at a time.
        /// If you want to be more efficient for multiple events then you
        /// should use the lower level interfaces for the xev backend.
        pub fn poll(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            event: xev.PollEvent,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.PollError!xev.PollEvent,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = switch (xev.backend) {
                    .io_uring => .{ .poll = .{
                        .fd = self.fd,
                        .events = switch (event) {
                            .read => std.posix.POLL.IN,
                        },
                    } },

                    .epoll => .{ .poll = .{
                        .fd = self.fd,
                        .events = switch (event) {
                            .read => std.os.linux.EPOLL.IN,
                        },
                    } },

                    .kqueue => switch (options.read) {
                        .none => unreachable,

                        .recv => .{ .read = .{
                            .fd = self.fd,
                            .buffer = .{ .slice = &.{} },
                        } },

                        .read => .{ .read = .{
                            .fd = self.fd,
                            .buffer = .{ .slice = &.{} },
                        } },
                    },

                    .iocp,
                    .wasi_poll,
                    => @compileError("poll not supported on this backend"),
                },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const fd: Self = switch (xev.backend) {
                            .io_uring,
                            .epoll,
                            => T.initFd(c_inner.op.poll.fd),

                            .kqueue => T.initFd(c_inner.op.read.fd),

                            .iocp,
                            .wasi_poll,
                            => @compileError("poll not supported on this backend"),
                        };

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            fd,
                            xev.PollEvent.fromResult(c_inner, r),
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }
    };
}

pub fn Closeable(comptime xev: type, comptime T: type, comptime options: Options) type {
    if (xev.dynamic) return struct {
        const Self = T;

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
                r: xev.CloseError!void,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const BackendSelf = @field(api, options.type.?);
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: BackendSelf,
                            r_inner: api.CloseError!void,
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
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).close(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }
    };

    return struct {
        const Self = T;

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
                r: xev.CloseError!void,
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
        }
    };
}

pub fn Readable(comptime xev: type, comptime T: type, comptime options: Options) type {
    if (xev.dynamic) return struct {
        const Self = T;

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
                r: xev.ReadError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const BackendSelf = @field(api, options.type.?);
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: BackendSelf,
                            b_inner: api.ReadBuffer,
                            r_inner: xev.ReadError!usize,
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
                    ).read(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        buf.toBackend(tag),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }
    };

    return struct {
        const Self = T;

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
                r: xev.ReadError!usize,
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

                        .kqueue => kqueue: {
                            // If we're not reading any actual data, we don't
                            // need a threadpool since only read() is blocking.
                            switch (buf) {
                                .array => {},
                                .slice => |v| if (v.len == 0) break :kqueue {},
                            }

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
    if (xev.dynamic) return struct {
        const Self = T;

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
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const BackendSelf = @field(api, options.type.?);
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: BackendSelf,
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
                    ).write(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        buf.toBackend(tag),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn queueWrite(
            self: Self,
            loop: *xev.Loop,
            q: *xev.WriteQueue,
            req: *xev.WriteRequest,
            buf: xev.WriteBuffer,
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
                    const api = (comptime xev.superset(tag)).Api();
                    const BackendSelf = @field(api, options.type.?);
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            s_inner: BackendSelf,
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

                    // Ensure our WriteQueue has the correct tag, since it is
                    // regularly zero-initialized and our zero-init picks
                    // an arbitrary backend.
                    q.ensureTag(tag);

                    // Initialize our request since it is usually undefined.
                    req.* = @unionInit(
                        xev.WriteRequest,
                        @tagName(tag),
                        undefined,
                    );

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).queueWrite(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(q.value, @tagName(tag)),
                        &@field(req, @tagName(tag)),
                        buf.toBackend(tag),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }
    };

    return struct {
        const Self = T;

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
            q: *xev.WriteQueue,
            req: *xev.WriteRequest,
            buf: xev.WriteBuffer,
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
            req.* = .{ .full_write_buffer = buf };
            // Must be kept in sync with partial write logic inside the callback
            self.writeInit(&req.completion, buf);
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
                    //
                    // We only peek the request here (not pop) because we may
                    // need to rearm this write if the write was partial.
                    const req_inner: *xev.WriteRequest = q_inner.head.?;

                    const cb_res = write_result(c_inner, r);
                    var result: xev.WriteError!usize = cb_res.result;

                    // Checks whether the entire buffer was written, this is
                    // necessary to guarantee correct ordering of writes.
                    // If the write was partial, it re-submits the remainder of
                    // the buffer.
                    const queued_len = writeBufferLength(cb_res.buf);
                    if (cb_res.result) |written_len| {
                        if (written_len < queued_len) {
                            // Write remainder of the buffer, reusing the same completion
                            const rem_buf = writeBufferRemainder(cb_res.buf, written_len);
                            cb_res.writer.writeInit(&req_inner.completion, rem_buf);
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
                r: xev.WriteError!usize,
            ) xev.CallbackAction,
        ) void {
            self.writeInit(c, buf);
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
            result: xev.WriteError!usize,
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
        fn writeInit(
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

/// Creates a generic stream type that supports read, write, close, poll. This
/// can be used for any file descriptor that would exhibit normal blocking
/// behavior on read/write. This should NOT be used for local files because
/// local files have some special properties; you should use xev.File for that.
pub fn GenericStream(comptime xev: type) type {
    if (xev.dynamic) return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"Stream"});

        const S = Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .read = .read,
            .write = .write,
            .type = "Stream",
        });
        pub const close = S.close;
        pub const poll = S.poll;
        pub const read = S.read;
        pub const write = S.write;
        pub const writeInit = S.writeInit;
        pub const queueWrite = S.queueWrite;

        pub fn initFd(fd: std.posix.pid_t) Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        api.Stream.initFd(fd),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (xev.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        test {
            _ = GenericStreamTests(xev, Self);
        }
    };

    return struct {
        const Self = @This();

        /// The underlying file
        fd: std.posix.fd_t,

        const S = Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .read = .read,
            .write = .write,
        });
        pub const close = S.close;
        pub const poll = S.poll;
        pub const read = S.read;
        pub const write = S.write;
        pub const writeInit = S.writeInit;
        pub const queueWrite = S.queueWrite;

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

        test {
            _ = GenericStreamTests(xev, Self);
        }
    };
}

fn GenericStreamTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "Stream decls" {
            if (!@hasDecl(Impl, "S")) return;
            inline for (@typeInfo(Impl.S).@"struct".decls) |decl| {
                const Decl = @TypeOf(@field(Impl.S, decl.name));
                if (Decl == void) continue;
                if (!@hasDecl(Impl, decl.name)) {
                    @compileError("missing decl: " ++ decl.name);
                }
            }
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

            const parent = Impl.initFd(pty.parent);
            const child = Impl.initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            parent.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
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

            const parent = Impl.initFd(pty.parent);
            const child = Impl.initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            child.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
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

            // this test fails on x86_64 with a strange error but passes
            // on aarch64. for now, just let it go until we investigate.
            if (xev.dynamic and builtin.cpu.arch == .x86_64) return error.SkipZigTest;

            // Create the pty parent/child side.
            var pty = try Pty.init();
            defer pty.deinit();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            const parent = Impl.initFd(pty.parent);
            const child = Impl.initFd(pty.child);

            // Read
            var read_buf: [128]u8 = undefined;
            var read_len: ?usize = null;
            var c_read: xev.Completion = undefined;
            child.read(&loop, &c_read, .{ .slice = &read_buf }, ?usize, &read_len, (struct {
                fn callback(
                    ud: ?*?usize,
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

            // This should not block!
            try loop.run(.no_wait);
            try testing.expect(read_len == null);

            var write_queue: xev.WriteQueue = .{};
            var write_req: [2]xev.WriteRequest = undefined;

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
                        _: Impl,
                        _: xev.WriteBuffer,
                        r: xev.WriteError!usize,
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
                        _: Impl,
                        _: xev.WriteBuffer,
                        r: xev.WriteError!usize,
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
            if (!xev.dynamic) {
                try testing.expect(
                    xev.WriteRequest.from(c_result.?) == &write_req[1],
                );
            }
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
