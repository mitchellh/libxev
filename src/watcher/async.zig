/// "Wake up" an event loop from any thread using an async completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const common = @import("common.zig");

pub fn Async(comptime xev: type) type {
    return switch (xev.backend) {
        // Supported, uses eventfd
        .io_uring,
        .epoll,
        => AsyncEventFd(xev),

        // Supported, uses the backend API
        .wasi_poll => AsyncLoopState(xev, xev.Loop.threaded),

        // Supported, uses mach ports
        .kqueue => AsyncMachPort(xev),
    };
}

/// Async implementation using eventfd (Linux).
fn AsyncEventFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.ReadError;

        /// eventfd file descriptor
        fd: os.fd_t,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            return .{
                .fd = try std.os.eventfd(0, 0),
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            std.os.close(self.fd);
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
            _ = os.write(self.fd, &val) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        /// Common tests
        pub usingnamespace AsyncTests(xev, Self);
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

        /// The mach port
        port: os.system.mach_port_name_t,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            const mach_self = os.system.mach_task_self();

            // Allocate the port
            var mach_port: os.system.mach_port_name_t = undefined;
            switch (os.system.getKernError(os.system.mach_port_allocate(
                mach_self,
                @intFromEnum(os.system.MACH_PORT_RIGHT.RECEIVE),
                &mach_port,
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }
            errdefer _ = os.system.mach_port_deallocate(mach_self, mach_port);

            return .{
                .port = mach_port,
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            _ = os.system.mach_port_deallocate(
                os.system.mach_task_self(),
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
        fn drain(port: os.system.mach_port_name_t) void {
            var message: struct {
                header: os.system.mach_msg_header_t,
            } = undefined;

            while (true) {
                switch (os.system.getMachMsgError(os.system.mach_msg(
                    &message.header,
                    os.system.MACH_RCV_MSG | os.system.MACH_RCV_TIMEOUT,
                    0,
                    @sizeOf(@TypeOf(message)),
                    port,
                    os.system.MACH_MSG_TIMEOUT_NONE,
                    os.system.MACH_PORT_NULL,
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
            var msg: os.system.mach_msg_header_t = .{
                .msgh_bits = @intFromEnum(os.system.MACH_MSG_TYPE.MAKE_SEND_ONCE),
                .msgh_size = @sizeOf(os.system.mach_msg_header_t),
                .msgh_remote_port = self.port,
                .msgh_local_port = os.system.MACH_PORT_NULL,
                .msgh_voucher_port = undefined,
                .msgh_id = undefined,
            };

            return switch (os.system.getMachMsgError(
                os.system.mach_msg(
                    &msg,
                    os.system.MACH_SEND_MSG,
                    msg.msgh_size,
                    0,
                    os.system.MACH_PORT_NULL,
                    os.system.MACH_MSG_TIMEOUT_NONE,
                    os.system.MACH_PORT_NULL,
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
            };
        }

        /// Common tests
        pub usingnamespace AsyncTests(xev, Self);
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

        /// Common tests
        pub usingnamespace AsyncTests(xev, Self);
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
            var c_wait: xev.Completion = undefined;
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

            // Send a notification
            try notifier.notify();

            // Wait for wake
            try loop.run(.until_done);
            try testing.expect(wake);
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
            var c_wait: xev.Completion = undefined;
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
            var c_wait: xev.Completion = undefined;
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
