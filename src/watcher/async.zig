/// "Wake up" an event loop from any thread using an async completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;

pub fn Async(comptime xev: type) type {
    return switch (xev.backend) {
        // Supported, uses eventfd
        .io_uring,
        .epoll,
        => AsyncEventFd(xev),

        // Supported, uses the backend API
        .wasi_poll => AsyncLoopState(xev),

        // Supported, uses mach ports
        .kqueue => AsyncMachPort(xev),
    };
}

/// Async implementation that is deferred to the backend implementation
/// loop state.
fn AsyncLoopState(comptime xev: type) type {
    return struct {
        const Self = @This();

        c: *xev.Completion,

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.AsyncError;

        pub fn init(c: *xev.Completion) !Self {
            // Initialize the completion so we can modify it safely.
            c.* = .{
                .op = .{
                    .async_wait = .{},
                },
                .userdata = null,
                .callback = undefined,
            };

            return .{ .c = c };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            self.c.userdata = userdata;
            self.c.callback = (struct {
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
                        if (r.async_wait) |_| {} else |err| err,
                    });
                }
            }).callback;

            loop.add(self.c);
        }

        pub fn notify(self: Self, loop: *xev.Loop) !void {
            loop.async_notify(self.c);
        }

        /// Common tests
        pub usingnamespace AsyncTests(xev, Self);
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

        /// Completion associated with this async.
        c: *xev.Completion,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init(c: *xev.Completion) !Self {
            return .{
                .fd = try std.os.eventfd(0, 0),
                .c = c,
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
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            self.c.* = .{
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
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            if (r.read) |v| assert(v > 0) else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(self.c);
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
        pub fn notify(self: Self, loop: *xev.Loop) !void {
            _ = loop;

            // We want to just write "1" in the correct byte order as our host.
            const val = @bitCast([8]u8, @as(u64, 1));
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

        /// Completion associated with this async.
        c: *xev.Completion,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init(c: *xev.Completion) !Self {
            const mach_self = os.system.mach_task_self();

            // Allocate the port
            var mach_port: os.system.mach_port_name_t = undefined;
            switch (os.system.getKernError(os.system.mach_port_allocate(
                mach_self,
                @enumToInt(os.system.MACH_PORT_RIGHT.RECEIVE),
                &mach_port,
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }
            errdefer _ = os.system.mach_port_deallocate(mach_self, mach_port);

            return .{
                .port = mach_port,
                .c = c,
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
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            self.c.* = .{
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
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            if (r.machport) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(self.c);
        }

        /// Notify a loop to wake up synchronously. This should never block forever
        /// (it will always EVENTUALLY succeed regardless of if the loop is currently
        /// ticking or not).
        pub fn notify(self: Self, loop: *xev.Loop) !void {
            _ = loop;

            // This constructs an empty mach message. It has no data.
            var msg: os.system.mach_msg_header_t = .{
                .msgh_bits = @enumToInt(os.system.MACH_MSG_TYPE.MAKE_SEND_ONCE),
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
                else => return error.MachMsgFailed,

                // This is okay because it means that there was no more buffer
                // space meaning that the port will wake up.
                .SEND_NO_BUFFER => {},
            };
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

            var c_wait: xev.Completion = undefined;
            var notifier = try Impl.init(&c_wait);
            defer notifier.deinit();

            // Wait
            var wake: bool = false;
            notifier.wait(&loop, bool, &wake, (struct {
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
            try notifier.notify(&loop);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expect(wake);
        }

        test "async: notify first" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var c_wait: xev.Completion = undefined;
            var notifier = try Impl.init(&c_wait);
            defer notifier.deinit();

            // Send a notification
            try notifier.notify(&loop);

            // Wait
            var wake: bool = false;
            notifier.wait(&loop, bool, &wake, (struct {
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
    };
}
