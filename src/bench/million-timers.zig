const std = @import("std");
const Instant = std.time.Instant;
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

pub const NUM_TIMERS: usize = 10 * 1000 * 1000;

pub fn main() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa: GPA = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var cs = try alloc.alloc(xev.Completion, NUM_TIMERS);
    defer alloc.free(cs);

    const before_all = try Instant.now();
    var i: usize = 0;
    var timeout: u64 = 1;
    while (i < NUM_TIMERS) : (i += 1) {
        if (i % 1000 == 0) timeout += 1;
        const timer = try xev.Timer.init();
        timer.run(&loop, &cs[i], timeout, void, null, timerCallback);
    }

    const before_run = try Instant.now();
    try loop.run(.until_done);
    const after_run = try Instant.now();
    const after_all = try Instant.now();

    std.log.info("{d:.2} seconds total", .{@as(f64, @floatFromInt(after_all.since(before_all))) / 1e9});
    std.log.info("{d:.2} seconds init", .{@as(f64, @floatFromInt(before_run.since(before_all))) / 1e9});
    std.log.info("{d:.2} seconds dispatch", .{@as(f64, @floatFromInt(after_run.since(before_run))) / 1e9});
    std.log.info("{d:.2} seconds cleanup", .{@as(f64, @floatFromInt(after_all.since(after_run))) / 1e9});
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
