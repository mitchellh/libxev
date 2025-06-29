/// "Wake up" an event loop from any thread using an async completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const common = @import("common.zig");
const darwin = @import("../darwin.zig");

pub fn Async(comptime xev: type) type {
    if (xev.dynamic) return AsyncDynamic(xev);

    return switch (xev.backend) {
        // Supported, uses eventfd
        .io_uring,
        .epoll,
        => AsyncEventFd(xev),

        // Supported, uses the backend API
        .wasi_poll => AsyncLoopState(xev, xev.Loop.threaded),

        // Supported, uses mach port on Darwin and eventfd on BSD.
        .kqueue => if (comptime builtin.target.os.tag.isDarwin())
            AsyncMachPort(xev)
        else
            AsyncEventFd(xev),

        .iocp => AsyncIOCP(xev),
    };
}

/// Async implementation using eventfd (Unix/Linux).
fn AsyncEventFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.ReadError;

        /// eventfd file descriptor
        fd: posix.fd_t,

        /// This is only used for FreeBSD currently.
        extern "c" fn eventfd(initval: c_uint, flags: c_uint) c_int;

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            return .{
                .fd = switch (builtin.os.tag) {
                    // std.posix is unavailable on FreeBSD. We call the
                    // syscall directly.
                    //
                    // TODO: error handling
                    .freebsd => eventfd(
                        0,
                        0x100000 | 0x4, // EFD_CLOEXEC | EFD_NONBLOCK
                    ),

                    // Use std.posix if we can.
                    else => try std.posix.eventfd(
                        0,
                        std.os.linux.EFD.CLOEXEC |
                            std.os.linux.EFD.NONBLOCK,
                    ),
                },
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            std.posix.close(self.fd);
        }

        /// Wait for a message on this async. Note that async messages may be
        /// coalesced (or they may not be) so you should not expect a 1:1 mapping
        /// between send and wait.
        ///
        /// Just like the rest of libxev, the wait must be re-queued if you want
        /// to continue to be notified of async events.
        ///
        /// You should NOT register an async with multiple loops (the same loop
        /// is fine -- but unnecessary). The behavior when waiting on multiple
        /// loops is undefined.
        pub const wait = switch (xev.backend) {
            .io_uring, .epoll => waitPoll,
            .kqueue => waitRead,
            .iocp, .wasi_poll => @compileError("AsyncEventFd does not support wait for this backend"),
        };

        fn waitRead(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .read = .{
                        .fd = self.fd,
                        .buffer = .{ .array = undefined },
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
                            if (r.read) |v| assert(v > 0) else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        fn waitPoll(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    // We use a poll operation instead of a read operation
                    // because in Kernel 6.15.4, read was regressed for
                    // io_uring on eventfd/timerfd and would block forever.
                    // However, poll works fine.
                    .poll = .{
                        .fd = self.fd,
                        .events = posix.POLL.IN,
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
                        if (r.poll) |_| {
                            // We need to read so that we can consume the
                            // eventfd value. We only read 8 bytes because
                            // we only write up to 8 bytes and we own the fd.
                            // We ignore errors here because we expect the
                            // read to succeed given we just polled it.
                            var buf: [8]u8 = undefined;
                            _ = posix.read(c_inner.op.poll.fd, &buf) catch {};
                        } else |_| {
                            // We'll call the callback with the error later.
                        }

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.poll) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Notify a loop to wake up synchronously. This should never block forever
        /// (it will always EVENTUALLY succeed regardless of if the loop is currently
        /// ticking or not).
        ///
        /// The "c" value is the completion associated with the "wait".
        ///
        /// Internal details subject to change but if you're relying on these
        /// details then you may want to consider using a lower level interface
        /// using the loop directly:
        ///
        ///   - linux+io_uring: eventfd is used. If the eventfd write would block
        ///     (EAGAIN) then we assume success because the eventfd is full.
        ///
        pub fn notify(self: Self) !void {
            // We want to just write "1" in the correct byte order as our host.
            const val = @as([8]u8, @bitCast(@as(u64, 1)));
            _ = posix.write(self.fd, &val) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation using mach ports (Darwin).
///
/// This allocates a mach port per async request and sends to that mach
/// port to wake up the loop and trigger the completion.
fn AsyncMachPort(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.MachPortError;

        /// Missing Mach APIs from Zig stdlib. Data from xnu: osfmk/mach/port.h
        const mach_port_flavor_t = c_int;
        const mach_port_limits = extern struct { mpl_qlimit: c_uint };
        const MACH_PORT_LIMITS_INFO = 1;
        extern "c" fn mach_port_set_attributes(
            task: posix.system.ipc_space_t,
            name: posix.system.mach_port_name_t,
            flavor: mach_port_flavor_t,
            info: *anyopaque,
            count: darwin.mach_msg_type_number_t,
        ) posix.system.kern_return_t;
        extern "c" fn mach_port_destroy(
            task: posix.system.ipc_space_t,
            name: posix.system.mach_port_name_t,
        ) posix.system.kern_return_t;

        /// The mach port
        port: posix.system.mach_port_name_t,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            const mach_self = posix.system.mach_task_self();

            // Allocate the port
            var mach_port: posix.system.mach_port_name_t = undefined;
            switch (darwin.getKernError(posix.system.mach_port_allocate(
                mach_self,
                @intFromEnum(posix.system.MACH_PORT_RIGHT.RECEIVE),
                &mach_port,
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }
            errdefer _ = mach_port_destroy(mach_self, mach_port);

            // Insert a send right into the port since we also use this to send
            switch (darwin.getKernError(posix.system.mach_port_insert_right(
                mach_self,
                mach_port,
                mach_port,
                @intFromEnum(posix.system.MACH_MSG_TYPE.MAKE_SEND),
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }

            // Modify the port queue size to be 1 because we are only
            // using it for notifications and not for any other purpose.
            var limits: mach_port_limits = .{ .mpl_qlimit = 1 };
            switch (darwin.getKernError(mach_port_set_attributes(
                mach_self,
                mach_port,
                MACH_PORT_LIMITS_INFO,
                &limits,
                @sizeOf(@TypeOf(limits)),
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }

            return .{
                .port = mach_port,
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            _ = mach_port_destroy(
                posix.system.mach_task_self(),
                self.port,
            );
        }

        /// Wait for a message on this async. Note that async messages may be
        /// coalesced (or they may not be) so you should not expect a 1:1 mapping
        /// between send and wait.
        ///
        /// Just like the rest of libxev, the wait must be re-queued if you want
        /// to continue to be notified of async events.
        ///
        /// You should NOT register an async with multiple loops (the same loop
        /// is fine -- but unnecessary). The behavior when waiting on multiple
        /// loops is undefined.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .machport = .{
                        .port = self.port,
                        .buffer = .{ .array = undefined },
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
                        // Drain the mach port so that we only fire one
                        // notification even if many are queued.
                        drain(c_inner.op.machport.port);

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.machport) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Drain the given mach port. All message bodies are discarded.
        fn drain(port: posix.system.mach_port_name_t) void {
            var message: struct {
                header: darwin.mach_msg_header_t,
            } = undefined;

            while (true) {
                switch (darwin.getMachMsgError(darwin.mach_msg(
                    &message.header,
                    darwin.MACH_RCV_MSG | darwin.MACH_RCV_TIMEOUT,
                    0,
                    @sizeOf(@TypeOf(message)),
                    port,
                    darwin.MACH_MSG_TIMEOUT_NONE,
                    darwin.MACH_PORT_NULL,
                ))) {
                    // This means a read would've blocked, so we drained.
                    .RCV_TIMED_OUT => return,

                    // We dequeued, so we want to loop again.
                    .SUCCESS => {},

                    // We dequeued but the message had a body. We ignore
                    // message bodies for async so we are happy to discard
                    // it and continue.
                    .RCV_TOO_LARGE => {},

                    else => |err| {
                        std.log.warn("mach msg drain err, may duplicate async wakeups err={}", .{err});
                        return;
                    },
                }
            }
        }

        /// Notify a loop to wake up synchronously. This should never block forever
        /// (it will always EVENTUALLY succeed regardless of if the loop is currently
        /// ticking or not).
        pub fn notify(self: Self) !void {
            // This constructs an empty mach message. It has no data.
            var msg: darwin.mach_msg_header_t = .{
                // We use COPY_SEND which will not increment any send ref
                // counts because it'll reuse the existing send right.
                .msgh_bits = @intFromEnum(posix.system.MACH_MSG_TYPE.COPY_SEND),
                .msgh_size = @sizeOf(darwin.mach_msg_header_t),
                .msgh_remote_port = self.port,
                .msgh_local_port = darwin.MACH_PORT_NULL,
                .msgh_voucher_port = undefined,
                .msgh_id = undefined,
            };

            return switch (darwin.getMachMsgError(
                darwin.mach_msg(
                    &msg,
                    darwin.MACH_SEND_MSG | darwin.MACH_SEND_TIMEOUT,
                    msg.msgh_size,
                    0,
                    darwin.MACH_PORT_NULL,
                    0, // Fail instantly if the port is full
                    darwin.MACH_PORT_NULL,
                ),
            )) {
                .SUCCESS => {},
                else => |e| {
                    std.log.warn("mach msg err={}", .{e});
                    return error.MachMsgFailed;
                },

                // This is okay because it means that there was no more buffer
                // space meaning that the port will wake up.
                .SEND_NO_BUFFER => {},

                // This means that the send would've blocked because the
                // queue is full. We assume success because the port is full.
                .SEND_TIMED_OUT => {},
            };
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation that is deferred to the backend implementation
/// loop state. This is kind of a hacky implementation and not recommended
/// but its the only way currently to get asyncs to work on WASI.
fn AsyncLoopState(comptime xev: type, comptime threaded: bool) type {
    // TODO: we don't support threaded loop state async. We _can_ it just
    // isn't done yet. To support it we need to have some sort of mutex
    // to guard waiter below.
    if (threaded) return struct {};

    return struct {
        const Self = @This();

        wakeup: bool = false,
        waiter: ?struct {
            loop: *xev.Loop,
            c: *xev.Completion,
        } = null,

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.AsyncError;

        pub fn init() !Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .async_wait = .{},
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
                            if (r.async_wait) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);

            self.waiter = .{
                .loop = loop,
                .c = c,
            };

            if (self.wakeup) self.notify() catch {};
        }

        pub fn notify(self: *Self) !void {
            if (self.waiter) |w|
                w.loop.async_notify(w.c)
            else
                self.wakeup = true;
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation for IOCP.
fn AsyncIOCP(comptime xev: type) type {
    return struct {
        const Self = @This();
        const windows = std.os.windows;

        pub const WaitError = xev.Sys.AsyncError;

        guard: std.Thread.Mutex = .{},
        wakeup: bool = false,
        waiter: ?struct {
            loop: *xev.Loop,
            c: *xev.Completion,
        } = null,

        pub fn init() !Self {
            return Self{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{ .async_wait = .{} },
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
                            if (r.async_wait) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);

            self.guard.lock();
            defer self.guard.unlock();

            self.waiter = .{
                .loop = loop,
                .c = c,
            };

            if (self.wakeup) loop.async_notify(c);
        }

        pub fn notify(self: *Self) !void {
            self.guard.lock();
            defer self.guard.unlock();

            if (self.waiter) |w| {
                w.loop.async_notify(w.c);
            } else {
                self.wakeup = true;
            }
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

fn AsyncDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"Async"});
        pub const WaitError = xev.ErrorSet(&.{ "Async", "WaitError" });

        pub fn init() !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.Async.init(),
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

        pub fn notify(self: *Self) !void {
            switch (xev.backend) {
                inline else => |tag| try @field(
                    self.backend,
                    @tagName(tag),
                ).notify(),
            }
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
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
                            r_inner: api.Async.WaitError!void,
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
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

fn AsyncTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "async" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .rearm;
                }
            }).callback);

            // Send a notification
            try notifier.notify();

            // Wait for wake
            try loop.run(.once);
            try testing.expect(wake);

            // Make sure it only triggers once
            wake = false;
            try loop.run(.no_wait);
            try testing.expect(!wake);
        }

        test "async: notify first" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Send a notification
            try notifier.notify();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expect(wake);
        }

        test "async batches multiple notifications" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Send a notification many times
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();

            // Wait
            var count: u32 = 0;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, u32, &count, (struct {
                fn callback(
                    ud: ?*u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* += 1;
                    return .rearm;
                }
            }).callback);

            // Send a notification
            try notifier.notify();

            // Wait for wake
            try loop.run(.once);
            for (0..10) |_| try loop.run(.no_wait);
            try testing.expectEqual(@as(u32, 1), count);
        }
    };
}
