const std = @import("std");
const builtin = @import("builtin");

const buf = @import("buf.zig");

/// The recommended system option given the build options.
pub const Loop = IO_Uring;
pub const Completion = Loop.Completion;
pub const Result = Loop.Result;
pub const Socket = @import("Socket.zig");
pub const ReadBuffer = buf.ReadBuffer;
pub const WriteBuffer = buf.WriteBuffer;

/// System-specific interfaces. Note that they are always exported for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist.
pub const IO_Uring = @import("linux/IO_Uring.zig");

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = Loop;
    _ = Socket;

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        else => {},
    }
}
