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
    if (comptime xev.dynamic) try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize all our threads
    var contexts: [thread_count]Thread = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    var comps: [contexts.len]xev.Completion = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = try Thread.init();
        ctx.main_async.wait(&loop, &comps[i], Thread, ctx, mainAsyncCallback);
        threads[i] = try std.Thread.spawn(.{}, Thread.threadMain, .{ctx});
    }

    const start_time = try Instant.now();
    try loop.run(.until_done);
    for (&threads) |thr| thr.join();
    const end_time = try Instant.now();

    const elapsed = @as(f64, @floatFromInt(end_time.since(start_time)));
    std.log.info("async{d}: {d:.2} seconds ({d:.2}/sec)", .{
        thread_count,
        elapsed / 1e9,
        NUM_PINGS / (elapsed / 1e9),
    });
}

fn mainAsyncCallback(
    ud: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;

    const self = ud.?;
    self.worker_async.notify() catch unreachable;
    self.main_sent += 1;
    self.main_seen += 1;

    return if (self.main_sent >= NUM_PINGS) .disarm else .rearm;
}

/// The thread state
const Thread = struct {
    loop: xev.Loop,
    worker_async: xev.Async,
    main_async: xev.Async,
    worker_sent: usize = 0,
    worker_seen: usize = 0,
    main_sent: usize = 0,
    main_seen: usize = 0,

    pub fn init() !Thread {
        return .{
            .loop = try xev.Loop.init(.{}),
            .worker_async = try xev.Async.init(),
            .main_async = try xev.Async.init(),
        };
    }

    pub fn threadMain(self: *Thread) !void {
        // Kick us off
        try self.main_async.notify();

        // Start our waiter
        var c: xev.Completion = undefined;
        self.worker_async.wait(&self.loop, &c, Thread, self, asyncCallback);

        // Run
        try self.loop.run(.until_done);
        if (self.worker_sent < NUM_PINGS) @panic("FAIL");
    }

    fn asyncCallback(
        ud: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        const self = ud.?;
        self.main_async.notify() catch unreachable;
        self.worker_sent += 1;
        self.worker_seen += 1;
        return if (self.worker_sent >= NUM_PINGS) .disarm else .rearm;
    }
};
