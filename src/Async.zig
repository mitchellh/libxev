/// "Wake up" an event loop from any thread using an async completion.
pub const Async = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

/// eventfd file descriptor
fd: os.fd_t,

/// Create a new async.
pub fn init() !Async {
    return .{
        .fd = try std.os.eventfd(0, 0),
    };
}

/// Wait for a message on this async. Note that async messages may be
/// coalesced (or they may not be) so you should not expect a 1:1 mapping
/// between send and wait.
pub fn wait(
    self: Async,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .read = .{
                .socket = self.fd,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}
