/// "Wake up" an event loop from any thread using an async completion.
pub const Async = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

/// The error that can come in the wait callback.
pub const WaitError = xev.Loop.ReadError;

/// eventfd file descriptor
fd: os.fd_t,

/// Create a new async. An async can be assigned to exactly one loop
/// to be woken up.
pub fn init() !Async {
    return .{
        .fd = try std.os.eventfd(0, 0),
    };
}

/// Clean up the async. This will forcibly deinitialize any resources
/// and may result in erroneous wait callbacks to be fired.
pub fn deinit(self: *Async) void {
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
    self: Async,
    loop: *xev.Loop,
    c: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: WaitError!void,
    ) void,
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
            fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
                @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@alignOf(Userdata), ud)),
                    c_inner,
                    if (r.read) |_| {} else |err| err,
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
pub fn notify(self: Async) !void {
    // We want to just write "1" in the correct byte order as our host.
    const val = @bitCast([8]u8, @as(u64, 1));
    _ = os.write(self.fd, &val) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}

test "async" {
    const testing = std.testing;
    _ = testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    var notifier = try init();
    defer notifier.deinit();

    // Wait
    var wake: bool = false;
    var c_wait: xev.Completion = undefined;
    notifier.wait(&loop, &c_wait, bool, &wake, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: WaitError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);

    // Send a notification
    try notifier.notify();

    // Wait for wake
    while (!wake) try loop.tick();
}

test "async: notify first" {
    const testing = std.testing;
    _ = testing;

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
        fn callback(ud: ?*bool, c: *xev.Completion, r: WaitError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);

    // Wait for wake
    while (!wake) try loop.tick();
}
