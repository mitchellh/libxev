const std = @import("std");
const Instant = std.time.Instant;
const xev = @import("xev");

pub fn main() !void {
    // Initialize the loop state. Notice we can use a stack-allocated
    // value here. We can even pass around the loop by value! The loop
    // will contain all of our "completions" (watches).
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize a completion and a watcher. A completion is the actual
    // thing a loop does for us, and a watcher is a high-level structure
    // to help make it easier to use completions.
    var c: xev.Completion = undefined;
    const timer = try xev.Timer.init();
    timer.run(&loop, &c, 1, void, null, timerCallback);

    // Run the loop until there are no more completions.
    try loop.run(.until_done);
}

fn timerCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    return .disarm;
}
