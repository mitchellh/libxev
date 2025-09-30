const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");
//const xev = @import("xev").Dynamic;

pub const std_options: std.Options = .{
    .log_level = .info,
};

// Tune-ables
pub const NUM_PINGS = 1000 * 1000;

pub fn main() !void {
    try run(1);
}

pub fn run(comptime thread_count: comptime_int) !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    if (xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    // Create our async
    notifier = try xev.Async.init();
    defer notifier.deinit();

    const userdata: ?*void = null;
    var c: xev.Completion = undefined;
    notifier.wait(&loop, &c, void, userdata, &asyncCallback);

    // Initialize all our threads
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thr| {
        thr.* = try std.Thread.spawn(.{}, threadMain, .{});
    }

    const start_time = try Instant.now();
    try loop.run(.until_done);
    for (&threads) |thr| thr.join();
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("async_pummel_{d}: {d} callbacks in {d:.2} seconds ({d:.2}/sec)", .{
        thread_count,
        callbacks,
        elapsed / 1e9,
        @as(f64, @floatFromInt(callbacks)) / (elapsed / 1e9),
    });
}

var callbacks: usize = 0;
var notifier: xev.Async = undefined;
var state: enum { running, stop, stopped } = .running;

fn asyncCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;

    callbacks += 1;
    if (callbacks < NUM_PINGS) return .rearm;

    // We're done
    state = .stop;
    while (state != .stopped) std.Thread.sleep(0);
    return .disarm;
}

fn threadMain() !void {
    while (state == .running) try notifier.notify();
    state = .stopped;
}
