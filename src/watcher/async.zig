/// "Wake up" an event loop from any thread using an async completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;

pub fn Async(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Loop.ReadError;

        /// eventfd file descriptor
        fd: os.fd_t,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up.
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
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
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
        /// Internal details subject to change but if you're relying on these
        /// details then you may want to consider using a lower level interface
        /// using the loop directly:
        ///
        ///   - linux+io_uring: eventfd is used. If the eventfd write would block
        ///     (EAGAIN) then we assume success because the eventfd is full.
        ///
        pub fn notify(self: Self) !void {
            // We want to just write "1" in the correct byte order as our host.
            const val = @bitCast([8]u8, @as(u64, 1));
            _ = os.write(self.fd, &val) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        test "async" {
            const testing = std.testing;

            var loop = try xev.Loop.init(16);
            defer loop.deinit();

            var notifier = try init();
            defer notifier.deinit();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = undefined;
            notifier.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: WaitError!void,
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

            var loop = try xev.Loop.init(16);
            defer loop.deinit();

            var notifier = try init();
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
                    r: WaitError!void,
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
