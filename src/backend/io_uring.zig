const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const queue = @import("../queue.zig");
const xev = @import("../main.zig").IO_Uring;

pub const Loop = struct {
    ring: linux.IO_Uring,

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that failed to enqueue.
    submissions: queue.Intrusive(Completion) = .{},

    /// Cached time
    now: std.os.timespec = undefined,

    flags: packed struct {
        /// True if the "now" field is outdated and should be updated
        /// when it is used.
        now_outdated: bool = true,

        /// Whether the loop is stopped or not.
        stopped: bool = false,

        /// Whether we're in a run or not (to prevent nested runs).
        in_run: bool = false,
    } = .{},

    /// Initialize the event loop. "entries" is the maximum number of
    /// submissions that can be queued at one time. The number of completions
    /// always matches the number of entries so the memory allocated will be
    /// 2x entries (plus the basic loop overhead).
    pub fn init(options: xev.Options) !Loop {
        const entries = std.math.cast(u13, options.entries) orelse
            return error.TooManyEntries;

        var result: Loop = .{
            // TODO(mitchellh): add an init_advanced function or something
            // for people using the io_uring API directly to be able to set
            // the flags for this.
            .ring = try linux.IO_Uring.init(entries, 0),
        };
        result.update_now();

        return result;
    }

    pub fn deinit(self: *Loop) void {
        self.ring.deinit();
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick_(.no_wait),
            .once => try self.tick_(.once),
            .until_done => try self.tick_(.until_done),
        }
    }

    /// Stop the loop. This can only be called from the main thread.
    /// This will stop the loop forever. Future ticks will do nothing.
    /// All completions are safe to read/write once any outstanding
    /// `run` or `tick` calls are returned.
    pub fn stop(self: *Loop) void {
        self.flags.stopped = true;
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &self.now) catch {};
        self.flags.now_outdated = false;
    }

    /// Tick the loop. The mode is comptime so we can do some tricks to
    /// avoid function calls and runtime branching.
    fn tick_(self: *Loop, comptime mode: xev.RunMode) !void {
        // We can't nest runs.
        if (self.flags.in_run) return error.NestedRunsNotAllowed;
        self.flags.in_run = true;
        defer self.flags.in_run = false;

        // The total number of events we're waiting for.
        const wait = switch (mode) {
            // until_done is one because we need to wait for at least one
            // (if we have any).
            .until_done => 1,
            .once => 1,
            .no_wait => 0,
        };

        var cqes: [128]linux.io_uring_cqe = undefined;
        while (true) {
            // If we're stopped then the loop is fully over.
            if (self.flags.stopped or
                (self.active == 0 and self.submissions.empty())) break;

            // If we have no queued submissions then we do the wait as part
            // of the submit call, because then we can do exactly once syscall
            // to get all our events.
            if (self.submissions.empty()) {
                _ = try self.ring.submit_and_wait(wait);
            } else {
                // We have submissions, meaning we have to do multiple submissions
                // anyways so we always just do non-waiting ones.
                _ = try self.submit();
            }

            // We always note that our "now" value is outdated.
            self.flags.now_outdated = true;

            // Wait for completions...
            const count = self.ring.copy_cqes(&cqes, wait) catch |err| return err;
            for (cqes[0..count]) |cqe| {
                const c = @intToPtr(*Completion, @intCast(usize, cqe.user_data));
                self.active -= 1;
                switch (c.invoke(self, cqe.res)) {
                    .disarm => {},
                    .rearm => self.add(c),
                }
            }

            // Subtract our waiters. If we reached zero then we're done.
            switch (mode) {
                .no_wait => break,
                .once => if (count > 0) break,
                .until_done => {},
            }
        }
    }

    /// Submit all queued operations. This never does an io_uring submit
    /// and wait operation.
    pub fn submit(self: *Loop) !void {
        _ = try self.ring.submit();

        // If we have any submissions that failed to submit, we try to
        // send those now. We have to make a copy so that any failures are
        // resubmitted without an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};
        while (queued.pop()) |c| self.add_(c, true);
    }

    /// Add a timer to the loop. The timer will initially execute in "next_ms"
    /// from now and will repeat every "repeat_ms" thereafter. If "next_ms" is
    /// zero then the timer will invoke on the next loop tick.
    ///
    /// If next_ms is too large of a value that it doesn't fit into the
    /// kernel time structure, the maximum sleep value will be used for your
    /// system (this is at least 45 days on a 32-bit system, and thousands of
    /// years on a 64-bit system).
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        // Get the timestamp of the absolute time that we'll execute this timer.
        // There are lots of failure scenarios here in math. If we see any
        // of them we just use the maximum value.
        const next_ts: std.os.linux.kernel_timespec = next_ts: {
            const max: std.os.linux.kernel_timespec = .{
                .tv_sec = std.math.maxInt(isize),
                .tv_nsec = std.math.maxInt(isize),
            };

            const next_s = std.math.cast(isize, next_ms / std.time.ms_per_s) orelse
                break :next_ts max;
            const next_ns = std.math.cast(isize, next_ms % std.time.ms_per_s) orelse
                break :next_ts max;

            if (self.flags.now_outdated) self.update_now();

            break :next_ts .{
                .tv_sec = std.math.add(isize, self.now.tv_sec, next_s) catch
                    break :next_ts max,
                .tv_nsec = std.math.add(isize, self.now.tv_nsec, next_ns) catch
                    break :next_ts max,
            };
        };

        c.* = .{
            .op = .{
                .timer = .{
                    .next = next_ts,
                },
            },
            .userdata = userdata,
            .callback = cb,
        };

        self.add(c);
    }

    /// Add a completion to the loop. This does NOT start the operation!
    /// You must call "submit" at some point to submit all of the queued
    /// work.
    pub fn add(self: *Loop, completion: *Completion) void {
        self.add_(completion, false);
    }

    /// Internal add function. The only difference is try_submit. If try_submit
    /// is true, then this function will attempt to submit the queue to the
    /// ring if the submission queue is full rather than filling up our FIFO.
    inline fn add_(
        self: *Loop,
        completion: *Completion,
        try_submit: bool,
    ) void {
        const sqe = self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => retry: {
                // If the queue is full and we're in try_submit mode then we
                // attempt to submit. This is used during submission flushing.
                if (try_submit) {
                    if (self.submit()) {
                        // Submission succeeded but we may still fail (unlikely)
                        // to get an SQE...
                        if (self.ring.get_sqe()) |sqe| {
                            break :retry sqe;
                        } else |retry_err| switch (retry_err) {
                            error.SubmissionQueueFull => {},
                        }
                    } else |_| {}
                }

                // Add the completion to our submissions to try to flush later.
                self.submissions.push(completion);
                return;
            },
        };

        // Increase active to the amount in the ring.
        self.active += 1;

        // Setup the submission depending on the operation
        switch (completion.op) {
            // Do nothing with noop completions.
            .noop => {
                self.active -= 1;
                return;
            },

            .accept => |*v| linux.io_uring_prep_accept(
                sqe,
                v.socket,
                &v.addr,
                &v.addr_size,
                v.flags,
            ),

            .close => |v| linux.io_uring_prep_close(
                sqe,
                v.fd,
            ),

            .connect => |*v| linux.io_uring_prep_connect(
                sqe,
                v.socket,
                &v.addr.any,
                v.addr.getOsSockLen(),
            ),

            .read => |*v| switch (v.buffer) {
                .array => |*buf| linux.io_uring_prep_read(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),

                .slice => |buf| linux.io_uring_prep_read(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),
            },

            .recv => |*v| switch (v.buffer) {
                .array => |*buf| linux.io_uring_prep_recv(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),

                .slice => |buf| linux.io_uring_prep_recv(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),
            },

            .recvmsg => |*v| {
                linux.io_uring_prep_recvmsg(
                    sqe,
                    v.fd,
                    v.msghdr,
                    0,
                );
            },

            .send => |*v| switch (v.buffer) {
                .array => |*buf| linux.io_uring_prep_send(
                    sqe,
                    v.fd,
                    buf.array[0..buf.len],
                    0,
                ),

                .slice => |buf| linux.io_uring_prep_send(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),
            },

            .sendmsg => |*v| {
                if (v.buffer) |_| {
                    @panic("TODO: sendmsg with buffer");
                }

                linux.io_uring_prep_sendmsg(
                    sqe,
                    v.fd,
                    v.msghdr,
                    0,
                );
            },

            .shutdown => |v| linux.io_uring_prep_shutdown(
                sqe,
                v.socket,
                switch (v.how) {
                    .both => linux.SHUT.RDWR,
                    .send => linux.SHUT.WR,
                    .recv => linux.SHUT.RD,
                },
            ),

            .timer => |*v| linux.io_uring_prep_timeout(
                sqe,
                &v.next,
                0,
                linux.IORING_TIMEOUT_ABS,
            ),

            .timer_remove => |v| linux.io_uring_prep_timeout_remove(
                sqe,
                @ptrToInt(v.timer),
                0,
            ),

            .write => |*v| switch (v.buffer) {
                .array => |*buf| linux.io_uring_prep_write(
                    sqe,
                    v.fd,
                    buf.array[0..buf.len],
                    0,
                ),

                .slice => |buf| linux.io_uring_prep_write(
                    sqe,
                    v.fd,
                    buf,
                    0,
                ),
            },
        }

        // Our sqe user data always points back to the completion.
        // The prep functions above reset the user data so we have to do this
        // here.
        sqe.user_data = @ptrToInt(completion);
    }
};

/// A completion represents a single queued request in the ring.
/// Completions must have stable pointers.
///
/// For the lowest overhead, these can be created manually and queued
/// directly. The API over the individual fields isn't the most user-friendly
/// since it is tune for performance. For user-friendly operations,
/// use the higher-level functions on this structure or the even
/// higher-level abstractions like the Timer struct.
pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback = xev.noopCallback,

    /// Internally set
    next: ?*Completion = null,

    /// Invokes the callback for this completion after properly constructing
    /// the Result based on the res code.
    fn invoke(self: *Completion, loop: *Loop, res: i32) xev.CallbackAction {
        const result: Result = switch (self.op) {
            .noop => unreachable,

            .accept => .{
                .accept = if (res >= 0)
                    @intCast(std.os.socket_t, res)
                else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .close => .{
                .close = if (res >= 0) {} else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .connect => .{
                .connect = if (res >= 0) {} else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .read => .{
                .read = self.readResult(.read, res),
            },

            .recv => .{
                .recv = self.readResult(.recv, res),
            },

            .recvmsg => .{
                .recvmsg = self.readResult(.recvmsg, res),
            },

            .send => .{
                .send = if (res >= 0)
                    @intCast(usize, res)
                else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .sendmsg => .{
                .sendmsg = if (res >= 0)
                    @intCast(usize, res)
                else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .shutdown => .{
                .shutdown = if (res >= 0) {} else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .timer => .{
                .timer = if (res >= 0) .request else switch (@intToEnum(std.os.E, -res)) {
                    .TIME => .expiration,
                    .CANCELED => .cancel,
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .timer_remove => .{
                .timer_remove = if (res >= 0) {} else switch (@intToEnum(std.os.E, -res)) {
                    .NOENT => error.NotFound,
                    .BUSY => error.ExpirationInProgress,
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .write => .{
                .write = if (res >= 0)
                    @intCast(usize, res)
                else switch (@intToEnum(std.os.E, -res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },
        };

        return self.callback(self.userdata, loop, self, result);
    }

    fn readResult(self: *Completion, comptime op: OperationType, res: i32) ReadError!usize {
        if (res > 0) {
            return @intCast(usize, res);
        }

        if (res == 0) {
            const active = @field(self.op, @tagName(op));
            if (!@hasField(@TypeOf(active), "buffer")) return ReadError.EOF;

            // If we receieve a zero byte read, it is an EOF _unless_
            // the requestesd buffer size was zero (weird).
            return switch (active.buffer) {
                .slice => |b| if (b.len == 0) 0 else ReadError.EOF,
                .array => ReadError.EOF,
            };
        }

        return switch (@intToEnum(std.os.E, -res)) {
            else => |errno| std.os.unexpectedErrno(errno),
        };
    }
};

pub const OperationType = enum {
    /// Do nothing. This operation will not be queued and will never
    /// have its callback fired. This is NOT equivalent to the io_uring
    /// "nop" operation.
    noop,

    /// Accept a connection on a socket.
    accept,

    /// Close a file descriptor.
    close,

    /// Initiate a connection on a socket.
    connect,

    /// Read
    read,

    /// Receive a message from a socket.
    recv,

    /// Send a message on a socket.
    send,

    /// Send a message on a socket using sendmsg (i.e. UDP).
    sendmsg,

    /// Recieve a message on a socket using recvmsg (i.e. UDP).
    recvmsg,

    /// Shutdown all or part of a full-duplex connection.
    shutdown,

    /// Write
    write,

    /// A oneshot or repeating timer. For io_uring, this is implemented
    /// using the timeout mechanism.
    timer,

    /// Cancel an existing timer.
    timer_remove,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    noop: void,
    accept: AcceptError!std.os.socket_t,
    connect: ConnectError!void,
    close: CloseError!void,
    read: ReadError!usize,
    recv: ReadError!usize,
    send: WriteError!usize,
    sendmsg: WriteError!usize,
    recvmsg: ReadError!usize,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
    timer_remove: TimerRemoveError!void,
    write: WriteError!usize,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    noop: void,

    accept: struct {
        socket: std.os.socket_t,
        addr: std.os.sockaddr = undefined,
        addr_size: std.os.socklen_t = @sizeOf(std.os.sockaddr),
        flags: u32 = std.os.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: std.os.socket_t,
        addr: std.net.Address,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    recv: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    recvmsg: struct {
        fd: std.os.fd_t,
        msghdr: *std.os.msghdr,
    },

    send: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    sendmsg: struct {
        fd: std.os.fd_t,
        msghdr: *std.os.msghdr_const,

        /// Optionally, a write buffer can be specified and the given
        /// msghdr will be populated with information about this buffer.
        buffer: ?WriteBuffer = null,

        /// Do not use this, it is only used internally.
        iov: [1]std.os.iovec_const = undefined,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        how: std.os.ShutdownHow = .both,
    },

    timer: struct {
        next: std.os.linux.kernel_timespec,
    },

    timer_remove: struct {
        timer: *Completion,
    },

    write: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },
};

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// To know the size read you have to use the return value of the
    /// read operations (i.e. recv).
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: struct {
        array: [32]u8,
        len: usize,
    },

    // TODO: future will have vectors
};

pub const AcceptError = error{
    Unexpected,
};

pub const CancelError = TimerRemoveError || error{
    Unexpected,
};

pub const CloseError = error{
    Unexpected,
};

pub const ConnectError = error{
    Unexpected,
};

pub const ReadError = error{
    EOF,
    Unexpected,
};

pub const ShutdownError = error{
    Unexpected,
};

pub const WriteError = error{
    Unexpected,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerRemoveError = error{
    NotFound,
    ExpirationInProgress,
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Timer completed due to linked request completing in time.
    request,

    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,
};

test "Completion size" {
    const testing = std.testing;

    // Just so we are aware when we change the size
    try testing.expectEqual(@as(usize, 144), @sizeOf(Completion));
}

test "io_uring: overflow entries count" {
    const testing = std.testing;

    {
        var loop = try Loop.init(.{});
        defer loop.deinit();
    }

    {
        try testing.expectError(error.TooManyEntries, Loop.init(.{
            .entries = std.math.pow(u14, 2, 13),
        }));
    }
}

test "io_uring: default completion" {
    //const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    var c: Completion = .{};
    loop.add(&c);

    // Tick
    try loop.run(.until_done);
}

test "io_uring: timerfd" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("../linux/timerfd.zig").Timerfd;
    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();
    try t.set(0, &.{ .value = .{ .nanoseconds = 1 } }, null);

    // Add the timer
    var called = false;
    var c: Completion = .{
        .op = .{
            .read = .{
                .fd = t.fd,
                .buffer = .{ .array = undefined },
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = c;
                _ = r;
                _ = l;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
}

test "io_uring: timer" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);
}

test "io_uring: stop" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 1_000_000, &called, (struct {
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    try loop.run(.no_wait);
    try testing.expect(!called);

    // Stop
    loop.stop();
    try loop.run(.until_done);
    try testing.expect(!called);
}

test "io_uring: timer remove" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &called, (struct {
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            const b = @ptrCast(*bool, ud.?);
            const trigger = r.timer catch unreachable;
            b.* = trigger != .cancel;
            return .disarm;
        }
    }).callback);

    // Remove it
    var c_remove: Completion = .{
        .op = .{
            .timer_remove = .{
                .timer = &c1,
            },
        },

        .userdata = null,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = ud;
                _ = r.timer_remove catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_remove);

    // Tick
    try loop.run(.until_done);
    try testing.expect(!called);
}

test "io_uring: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const os = std.os;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(ln);
    try os.setsockopt(ln, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(ln, &address.any, address.getOsSockLen());
    try os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(client_conn);

    // Accept
    var server_conn: os.socket_t = 0;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                const conn = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                conn.* = r.accept catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: Completion = .{
        .op = .{
            .connect = .{
                .socket = client_conn,
                .addr = address,
            },
        },

        .userdata = &connected,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.connect catch unreachable;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_connect);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_conn > 0);
    try testing.expect(connected);

    // Send
    var c_send: Completion = .{
        .op = .{
            .send = .{
                .fd = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.send catch unreachable;
                _ = ud;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_send);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    var c_recv: Completion = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.recv catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, c_send.op.send.buffer.slice, recv_buf[0..recv_len]);

    // Shutdown
    var shutdown = false;
    var c_client_shutdown: Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_shutdown);
    try loop.run(.until_done);
    try testing.expect(shutdown);

    // Read should be EOF
    var eof: ?bool = null;
    c_recv = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?bool, @alignCast(@alignOf(?bool), ud.?));
                ptr.* = if (r.recv) |_| false else |err| switch (err) {
                    error.EOF => true,
                    else => false,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.run(.until_done);
    try testing.expect(eof.? == true);

    // Close
    var c_client_close: Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var c_server_close: Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(ln == 0);
    try testing.expect(client_conn == 0);
}

test "io_uring: sendmsg/recvmsg" {
    const mem = std.mem;
    const net = std.net;
    const os = std.os;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const server = try std.os.socket(address.any.family, std.os.SOCK.DGRAM, 0);
    defer std.os.close(server);
    try std.os.setsockopt(server, std.os.SOL.SOCKET, std.os.SO.REUSEPORT, &mem.toBytes(@as(c_int, 1)));
    try std.os.setsockopt(server, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try std.os.bind(server, &address.any, address.getOsSockLen());

    const client = try std.os.socket(address.any.family, std.os.SOCK.DGRAM, 0);
    defer std.os.close(client);

    // Send
    const buffer_send = [_]u8{42} ** 128;
    const iovecs_send = [_]os.iovec_const{
        os.iovec_const{ .iov_base = &buffer_send, .iov_len = buffer_send.len },
    };
    var msg_send = os.msghdr_const{
        .name = &address.any,
        .namelen = address.getOsSockLen(),
        .iov = &iovecs_send,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    var c_sendmsg: Completion = .{
        .op = .{
            .sendmsg = .{
                .fd = client,
                .msghdr = &msg_send,
            },
        },

        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.sendmsg catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_sendmsg);

    // Recv

    var buffer_recv = [_]u8{0} ** 128;
    var iovecs_recv = [_]os.iovec{
        os.iovec{ .iov_base = &buffer_recv, .iov_len = buffer_recv.len },
    };
    var addr = [_]u8{0} ** 4;
    var address_recv = net.Address.initIp4(addr, 0);
    var msg_recv: os.msghdr = os.msghdr{
        .name = &address_recv.any,
        .namelen = address_recv.getOsSockLen(),
        .iov = &iovecs_recv,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    var recv_size: usize = 0;
    var c_recvmsg: Completion = .{
        .op = .{
            .recvmsg = .{
                .fd = server,
                .msghdr = &msg_recv,
            },
        },

        .userdata = &recv_size,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, l: *xev.Loop, c: *xev.Completion, r: xev.Result) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.recvmsg catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recvmsg);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(recv_size == buffer_recv.len);
    try testing.expectEqualSlices(u8, buffer_send[0..buffer_recv.len], buffer_recv[0..]);
}
