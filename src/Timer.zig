/// A timer fires a callback after a specified amount of time and
/// can optionally repeat at a specified interval.
pub const Timer = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

/// Create a new timer.
pub fn init() !Timer {
    return .{};
}

pub fn deinit(self: *Timer) void {
    // Nothing for now.
    _ = self;
}

/// Start the timer. The timer will execute in next_ms milliseconds from
/// now.
///
/// This will use the monotonic clock on your system if available so
/// this is immune to system clock changes or drift. The callback is
/// guaranteed to fire NO EARLIER THAN "next_ms" milliseconds. We can't
/// make any guarantees about exactness or time bounds because its possible
/// for your OS to just... pause.. the process for an indefinite period of
/// time.
///
/// Like everything else in libxev, if you want something to repeat, you
/// must then requeue the completion manually. This punts off one of the
/// "hard" aspects of timers: it is up to you to determine what the semantic
/// meaning of intervals are. For example, if you want a timer to repeat every
/// 10 seconds, is it every 10th second of a wall clock? every 10th second
/// after an invocation? every 10th second after the work time from the
/// invocation? You have the power to answer these questions, manually.
pub fn run(
    self: Timer,
    loop: *xev.Loop,
    c: *xev.Completion,
    next_ms: u64,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: RunError!void,
    ) void,
) void {
    _ = self;

    loop.timer(c, next_ms, userdata, (struct {
        fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
            @call(.always_inline, cb, .{
                @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                c_inner,
                if (r.timer) |trigger| @as(RunError!void, switch (trigger) {
                    .request, .expiration => {},
                    .cancel => error.Canceled,
                }) else |err| err,
            });
        }
    }).callback);
}

/// Cancel a previously started timer. The timer to cancel used the completion
/// "c_cancel". A new completion "c" must be specified which will be called
/// with the callback once cancellation is complete.
///
/// The original timer will still have its callback fired but with the
/// error "error.Canceled".
pub fn cancel(
    self: Timer,
    loop: *xev.Loop,
    c: *xev.Completion,
    c_cancel: *xev.Completion,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        c: *xev.Completion,
        r: CancelError!void,
    ) void,
) void {
    _ = self;

    c.* = .{
        .op = .{
            .timer_remove = .{
                .timer = c_cancel,
            },
        },

        .userdata = userdata,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c_inner: *xev.Completion, r: xev.Result) void {
                @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                    c_inner,
                    if (r.timer_remove) |_| {} else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}

/// Error that could happen while running a timer.
pub const RunError = error{
    /// The timer was canceled before it could expire
    Canceled,

    /// Some unexpected error.
    Unexpected,
};

pub const CancelError = error{
    /// The timer to cancel was not found. It possibly already expired
    /// and has been dequeued.
    NotFound,

    /// The timer was found but it was already in process of being
    /// processed for expiration. It was not canceled.
    ExpirationInProgress,

    /// Unknown error
    Unexpected,
};

test "timer" {
    const testing = std.testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    var timer = try init();
    defer timer.deinit();

    // Add the timer
    var called = false;
    var c1: xev.Completion = undefined;
    timer.run(&loop, &c1, 1, bool, &called, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: RunError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);

    // Wait
    try loop.run(.until_done);
    try testing.expect(called);
}

test "timer cancel" {
    const testing = std.testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    var timer = try init();
    defer timer.deinit();

    // Add the timer
    var canceled = false;
    var c1: xev.Completion = undefined;
    timer.run(&loop, &c1, 100_000, bool, &canceled, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: RunError!void) void {
            _ = c;
            ud.?.* = if (r) false else |err| err == error.Canceled;
        }
    }).callback);

    // Cancel
    var cancel_confirm = false;
    var c2: xev.Completion = undefined;
    timer.cancel(&loop, &c2, &c1, bool, &cancel_confirm, (struct {
        fn callback(ud: ?*bool, c: *xev.Completion, r: CancelError!void) void {
            _ = c;
            _ = r catch unreachable;
            ud.?.* = true;
        }
    }).callback);

    // Wait
    try loop.run(.until_done);
    try testing.expect(canceled);
    try testing.expect(cancel_confirm);
}
