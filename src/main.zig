const std = @import("std");
const builtin = @import("builtin");

pub const loop = @import("loop.zig");
pub const Loop = loop.Loop(Sys);

/// The recommended system option given the build options.
pub const Sys = IO_Uring;

/// System-specific interfaces. Note that they are always exported for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist.
pub const IO_Uring = @import("linux/IO_Uring.zig");

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = loop;
    _ = Sys;

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        else => {},
    }
}
