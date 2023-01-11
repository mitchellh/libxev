const std = @import("std");
const builtin = @import("builtin");

/// The low-level IO interfaces using the recommended compile-time
/// interface for the target system.
pub const Loop = IO_Uring;
pub const Completion = Loop.Completion;
pub const Result = Loop.Result;
pub const ReadBuffer = Loop.ReadBuffer;
pub const WriteBuffer = Loop.WriteBuffer;

/// Common loop structures. The actual loop implementation is in backend-specific
/// files such as linux/io_uring.zig.
pub usingnamespace @import("loop.zig");

/// The high-level helper interfaces that make it easier to perform
/// common tasks. These may not work with all possible Loop implementations.
pub const Async = @import("Async.zig");
pub const TCP = @import("TCP.zig");
pub const Timer = @import("Timer.zig");

/// System-specific interfaces. Note that they are always exported for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist.
pub const IO_Uring = @import("linux/IO_Uring.zig");

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = Loop;
    _ = Async;
    _ = TCP;
    _ = Timer;

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        else => {},
    }
}
