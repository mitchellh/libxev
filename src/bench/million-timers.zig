const std = @import("std");
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

pub const NUM_TIMERS: usize = 10 * 1000 * 1000;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var cs = try alloc.alloc(xev.Completion, NUM_TIMERS);
    defer alloc.free(cs);

    const clock = std.Io.Clock.awake;
    const before_all = clock.now(io);
    var i: usize = 0;
    var timeout: u64 = 1;
    while (i < NUM_TIMERS) : (i += 1) {
        if (i % 1000 == 0) timeout += 1;
        const timer = try xev.Timer.init();
        timer.run(&loop, &cs[i], timeout, void, null, timerCallback);
    }

    const before_run = clock.now(io);
    try loop.run(.until_done);
    const after_run = clock.now(io);
    const after_all = clock.now(io);

    const dur = struct {
        fn ns(from: std.Io.Timestamp, to: std.Io.Timestamp) f64 {
            return @floatFromInt(from.durationTo(to).nanoseconds);
        }
    }.ns;

    std.log.info("{d:.2} seconds total", .{dur(before_all, after_all) / 1e9});
    std.log.info("{d:.2} seconds init", .{dur(before_all, before_run) / 1e9});
    std.log.info("{d:.2} seconds dispatch", .{dur(before_run, after_run) / 1e9});
    std.log.info("{d:.2} seconds cleanup", .{dur(after_run, after_all) / 1e9});
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

var timer_callback_count: usize = 0;

fn timerCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    timer_callback_count += 1;
    return .disarm;
}
