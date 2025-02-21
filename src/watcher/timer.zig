const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;

/// A timer fires a callback after a specified amount of time. A timer can
/// repeat by returning "rearm" in the callback or by rescheduling the
/// start within the callback.
pub fn Timer(comptime xev: type) type {
    if (xev.dynamic) return TimerDynamic(xev);
    return TimerLoop(xev);
}

/// An implementation that uses the loop timer methods.
fn TimerLoop(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// Create a new timer.
        pub fn init() !Self {
            return .{};
        }

        pub fn deinit(self: *const Self) void {
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
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: RunError!void,
            ) xev.CallbackAction,
        ) void {
            _ = self;

            loop.timer(c, next_ms, userdata, (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    return @call(.always_inline, cb, .{
                        @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud))),
                        l_inner,
                        c_inner,
                        if (r.timer) |trigger| @as(RunError!void, switch (trigger) {
                            .request, .expiration => {},
                            .cancel => error.Canceled,
                        }) else |err| err,
                    });
                }
            }).callback);
        }

        /// Reset a timer to execute in next_ms milliseconds. If the timer
        /// is already started, this will stop it and restart it. If the
        /// timer has never been started, this is equivalent to running "run".
        /// In every case, the timer callback is updated to the given userdata
        /// and callback.
        ///
        /// This requires an additional completion c_cancel to represent
        /// the need to possibly cancel the previous timer. You can check
        /// if c_cancel was used by checking the state() after the call.
        ///
        /// VERY IMPORTANT: both c and c_cancel MUST NOT be undefined. They
        /// must be initialized to ".{}" if being used for the first time.
        pub fn reset(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            c_cancel: *xev.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: RunError!void,
            ) xev.CallbackAction,
        ) void {
            _ = self;

            loop.timer_reset(c, c_cancel, next_ms, userdata, (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    return @call(.always_inline, cb, .{
                        @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud))),
                        l_inner,
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
            self: Self,
            loop: *xev.Loop,
            c_timer: *xev.Completion,
            c_cancel: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: CancelError!void,
            ) xev.CallbackAction,
        ) void {
            _ = self;

            c_cancel.* = switch (xev.backend) {
                .io_uring => .{
                    .op = .{
                        .timer_remove = .{
                            .timer = c_timer,
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
                                @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud))),
                                l_inner,
                                c_inner,
                                if (r.timer_remove) |_| {} else |err| err,
                            });
                        }
                    }).callback,
                },

                .epoll,
                .kqueue,
                .wasi_poll,
                .iocp,
                => .{
                    .op = .{
                        .cancel = .{
                            .c = c_timer,
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
                                @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud))),
                                l_inner,
                                c_inner,
                                if (r.cancel) |_| {} else |err| err,
                            });
                        }
                    }).callback,
                },
            };

            loop.add(c_cancel);
        }

        /// Error that could happen while running a timer.
        pub const RunError = error{
            /// The timer was canceled before it could expire
            Canceled,

            /// Some unexpected error.
            Unexpected,
        };

        pub const CancelError = xev.CancelError;

        test {
            _ = TimerTests(xev, Self);
        }
    };
}

fn TimerDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"Timer"});
        pub const RunError = xev.ErrorSet(&.{ "Timer", "RunError" });
        pub const CancelError = xev.ErrorSet(&.{ "Timer", "CancelError" });

        pub fn init() !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.Timer.init(),
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

        pub fn run(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: RunError!void,
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
                            r_inner: api.Timer.RunError!void,
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
                    ).run(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        next_ms,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn reset(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            c_cancel: *xev.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: RunError!void,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);
                    c_cancel.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Timer.RunError!void,
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
                    ).reset(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        &@field(c_cancel.value, @tagName(tag)),
                        next_ms,
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        pub fn cancel(
            self: Self,
            loop: *xev.Loop,
            c_timer: *xev.Completion,
            c_cancel: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: CancelError!void,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c_timer.ensureTag(tag);
                    c_cancel.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Timer.CancelError!void,
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
                    ).cancel(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c_timer.value, @tagName(tag)),
                        &@field(c_cancel.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = TimerTests(
                xev,
                Self,
            );
        }
    };
}

fn TimerTests(
    comptime xev: type,
    comptime Impl: type,
) type {
    return struct {
        test "timer" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try Impl.init();
            defer timer.deinit();

            // Add the timer
            var called = false;
            var c1: xev.Completion = undefined;
            timer.run(&loop, &c1, 1, bool, &called, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.RunError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait
            try loop.run(.until_done);
            try testing.expect(called);
        }

        test "timer reset" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try Impl.init();
            defer timer.deinit();

            var c_timer: xev.Completion = .{};
            var c_cancel: xev.Completion = .{};
            const cb = (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.RunError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback;

            // Add the timer
            var canceled = false;
            timer.run(&loop, &c_timer, 100_000, bool, &canceled, cb);

            // Wait
            try loop.run(.no_wait);
            try testing.expect(!canceled);

            // Reset it
            timer.reset(&loop, &c_timer, &c_cancel, 1, bool, &canceled, cb);

            try loop.run(.until_done);
            try testing.expect(canceled);
            try testing.expect(c_timer.state() == .dead);
            try testing.expect(c_cancel.state() == .dead);
        }

        test "timer reset before tick" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try Impl.init();
            defer timer.deinit();

            var c_timer: xev.Completion = .{};
            var c_cancel: xev.Completion = .{};
            const cb = (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.RunError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback;

            // Add the timer
            var canceled = false;
            timer.run(&loop, &c_timer, 100_000, bool, &canceled, cb);

            // Reset it
            timer.reset(&loop, &c_timer, &c_cancel, 1, bool, &canceled, cb);

            try loop.run(.until_done);
            try testing.expect(canceled);
            try testing.expect(c_timer.state() == .dead);
            try testing.expect(c_cancel.state() == .dead);
        }

        test "timer reset after trigger" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try Impl.init();
            defer timer.deinit();

            var c_timer: xev.Completion = .{};
            var c_cancel: xev.Completion = .{};
            const cb = (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.RunError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback;

            // Add the timer
            var canceled = false;
            timer.run(&loop, &c_timer, 1, bool, &canceled, cb);
            try loop.run(.until_done);
            try testing.expect(canceled);
            canceled = false;

            // Reset it
            timer.reset(&loop, &c_timer, &c_cancel, 1, bool, &canceled, cb);

            try loop.run(.until_done);
            try testing.expect(canceled);
            try testing.expect(c_timer.state() == .dead);
            try testing.expect(c_cancel.state() == .dead);
        }

        test "timer cancel" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try Impl.init();
            defer timer.deinit();

            // Add the timer
            var canceled = false;
            var c1: xev.Completion = undefined;
            timer.run(&loop, &c1, 100_000, bool, &canceled, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.RunError!void,
                ) xev.CallbackAction {
                    ud.?.* = if (r) false else |err| err == error.Canceled;
                    return .disarm;
                }
            }).callback);

            // Cancel
            var cancel_confirm = false;
            var c2: xev.Completion = undefined;
            timer.cancel(&loop, &c1, &c2, bool, &cancel_confirm, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.CancelError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait
            try loop.run(.until_done);
            try testing.expect(canceled);
            try testing.expect(cancel_confirm);
        }
    };
}
