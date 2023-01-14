const std = @import("std");
const builtin = @import("builtin");

/// The low-level IO interfaces using the recommended compile-time
/// interface for the target system.
pub usingnamespace Epoll;

/// System-specific interfaces. Note that they are always pub for
/// all systems but if you reference them and force them to be analyzed
/// the proper system APIs must exist. Due to Zig's lazy analysis, if you
/// don't use any interface it will NOT be compiled (yay!).
pub const IO_Uring = Xev(@import("linux/IO_Uring.zig"));
pub const Epoll = Xev(@import("Epoll.zig"));

/// Creates the Xev API based on a backend type.
///
/// For the default backend type for your system (i.e. io_uring on Linux),
/// this is the main API you interact with. It is `usingnamespaced` into
/// the "xev" package so you'd use types such as `xev.Loop`, `xev.Completion`,
/// etc.
///
/// Unless you're using a custom or specific backend type, you do NOT ever
/// need to call the Xev function itself.
pub fn Xev(comptime T: type) type {
    return struct {
        const Self = @This();
        const loop = @import("loop.zig");

        /// The core loop APIs.
        pub const Loop = T;
        pub const Completion = T.Completion;
        pub const Result = T.Result;
        pub const ReadBuffer = Loop.ReadBuffer;
        pub const WriteBuffer = Loop.WriteBuffer;
        pub const RunMode = loop.RunMode;
        pub const CallbackAction = loop.CallbackAction;

        /// The high-level helper interfaces that make it easier to perform
        /// common tasks. These may not work with all possible Loop implementations.
        pub const Async = @import("async.zig").Async(Self);
        pub const TCP = @import("tcp.zig").TCP(Self);
        pub const UDP = @import("udp.zig").UDP(Self);
        pub const Timer = @import("timer.zig").Timer(Self);

        /// The callback of the main Loop operations. Higher level interfaces may
        /// use a different callback mechanism.
        pub const Callback = *const fn (
            userdata: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction;

        test {
            @import("std").testing.refAllDecls(@This());
        }
    };
}

test {
    // Tested on all platforms
    _ = @import("heap.zig");
    _ = @import("queue.zig");

    // OS-specific tests
    switch (builtin.os.tag) {
        .linux => {
            _ = Epoll;
            _ = IO_Uring;
            _ = @import("linux/timerfd.zig");
        },

        else => {},
    }
}
