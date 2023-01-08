const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");

/// Loop is the cross-platform event loop abstraction given a specific
/// system interface backend.
pub fn Loop(comptime Sys: type) type {
    return struct {
        const Self = @This();

        /// The system interface for IO and other operations.
        sys: Sys,

        pub fn init(entries: u13) !Self {
            return .{
                .sys = try xev.Sys.init(entries),
            };
        }

        pub fn deinit(self: *Self) void {
            self.sys.deinit();
        }
    };
}

test "loop" {
    var loop = try xev.Loop.init(1024);
    defer loop.deinit();
}
