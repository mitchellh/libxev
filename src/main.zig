const std = @import("std");
const builtin = @import("builtin");

/// The recommended system option given the build options.
pub const Loop = IO_Uring;
pub const Completion = Loop.Completion;
pub const Result = Loop.Result;
pub const Async = @import("Async.zig");
pub const Socket = @import("Socket.zig");
pub const Timer = @import("Timer.zig");
pub const ReadBuffer = Loop.ReadBuffer;
pub const WriteBuffer = Loop.WriteBuffer;

/// System-specific interfaces. Note that they are always exported for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist.
pub const IO_Uring = @import("linux/IO_Uring.zig");

/// The loop run mode -- all backends are required to support this in some way.
/// Backends may provide backend-specific APIs that behave slightly differently
/// or in a more configurable way.
pub const RunMode = enum {
    /// Run the event loop once. If there are no blocking operations ready,
    /// return immediately.
    no_wait,

    /// Run the event loop once, waiting for at least one blocking operation
    /// to complete.
    once,

    /// Run the event loop until it is "done". "Doneness" is defined as
    /// there being no more completions that are active.
    until_done,
};

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");
    _ = Loop;
    _ = Async;
    _ = Socket;
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
