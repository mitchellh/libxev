const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;
const xev = @import("xev");

pub const log_level: std.log.Level = .info;

// Tune-ables
pub const NUM_PINGS = 1000 * 100;
pub const THR_COUNT = 1;
pub const wait = true;

// Done counter (TODO: remove)
pub var done: std.atomic.Atomic(usize) = .{ .value = 0 };

pub fn main() !void {
    var loop = try xev.Loop.init(std.math.pow(u13, 2, 12));
    defer loop.deinit();

    // Initialize all our threads
    var contexts: [THR_COUNT]Thread = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    var comps: [contexts.len]xev.Completion = undefined;
    for (contexts) |*ctx, i| {
        ctx.* = try Thread.init(&loop);
        ctx.main_async.wait(&loop, &comps[i], Thread, ctx, mainAsyncCallback);
        threads[i] = try std.Thread.spawn(.{}, Thread.threadMain, .{ctx});
    }

    const start_time = try Instant.now();
    if (wait) {
        try loop.run(.until_done);
    } else {
        while (done.loadUnchecked() < contexts.len) try loop.tick(0);
    }
    for (threads) |thr| thr.join();
    const end_time = try Instant.now();

    const elapsed = @intToFloat(f64, end_time.since(start_time));
    std.log.info("async{d}: {d:.2} seconds ({d:.2}/sec)", .{
        THR_COUNT,
        elapsed / 1e9,
        NUM_PINGS / (elapsed / 1e9),
    });
}

fn mainAsyncCallback(ud: ?*Thread, c: *xev.Completion, r: xev.Async.WaitError!void) void {
    _ = r catch unreachable;

    const self = ud.?;
    self.worker_async.notify() catch unreachable;
    self.main_sent += 1;
    self.main_seen += 1;
    if (self.main_sent >= NUM_PINGS) return;

    // Re-register the listener
    self.main_async.wait(self.main_loop, c, Thread, self, mainAsyncCallback);
}

/// The thread state
const Thread = struct {
    main_loop: *xev.Loop,
    loop: xev.Loop,
    worker_async: xev.Async,
    main_async: xev.Async,
    worker_sent: usize = 0,
    worker_seen: usize = 0,
    main_sent: usize = 0,
    main_seen: usize = 0,

    pub fn init(main_loop: *xev.Loop) !Thread {
        return .{
            .main_loop = main_loop,
            .loop = try xev.Loop.init(std.math.pow(u13, 2, 12)),
            .worker_async = try xev.Async.init(),
            .main_async = try xev.Async.init(),
        };
    }

    pub fn threadMain(self: *Thread) !void {
        defer _ = done.fetchAdd(1, .SeqCst);

        // Kick us off
        try self.main_async.notify();

        // Start our waiter
        var c: xev.Completion = undefined;
        self.worker_async.wait(&self.loop, &c, Thread, self, asyncCallback);

        // Run
        if (wait) {
            try self.loop.run(.until_done);
        } else {
            while (self.worker_sent < NUM_PINGS or
                self.main_sent < NUM_PINGS)
            {
                try self.loop.tick(0);
            }
        }
    }

    fn asyncCallback(ud: ?*Thread, c: *xev.Completion, r: xev.Async.WaitError!void) void {
        _ = r catch unreachable;
        const self = ud.?;
        self.main_async.notify() catch unreachable;
        self.worker_sent += 1;
        self.worker_seen += 1;
        if (self.worker_sent >= NUM_PINGS) return;

        // Re-register the listener
        self.worker_async.wait(&self.loop, c, Thread, self, asyncCallback);
    }
};
