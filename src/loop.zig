//! Common loop structures. The actual loop implementation is in backend-specific
//! files such as linux/io_uring.zig.

const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");

/// Common options across backends. Not all options apply to all backends.
/// Read the doc comment for individual fields to learn what backends they
/// apply to.
pub const Options = struct {
    /// The number of queued completions that can be in flight before
    /// requiring interaction with the kernel.
    ///
    /// Backends: io_uring
    entries: u32 = 256,

    /// A thread pool to use for blocking operations. If the backend doesn't
    /// need to perform any blocking operations then no threads will ever
    /// be spawned. If the backend does need to perform blocking operations
    /// on a thread and no thread pool is provided, the operations will simply
    /// fail. Unless you're trying to really optimize for space, it is
    /// recommended you provide a thread pool.
    ///
    /// Backends: epoll, kqueue
    thread_pool: ?*xev.ThreadPool = null,
};

/// The loop run mode -- all backends are required to support this in some way.
/// Backends may provide backend-specific APIs that behave slightly differently
/// or in a more configurable way.
pub const RunMode = enum(c_int) {
    /// Run the event loop once. If there are no blocking operations ready,
    /// return immediately.
    no_wait = 0,

    /// Run the event loop once, waiting for at least one blocking operation
    /// to complete.
    once = 1,

    /// Run the event loop until it is "done". "Doneness" is defined as
    /// there being no more completions that are active.
    until_done = 2,
};

/// The callback of the main Loop operations. Higher level interfaces may
/// use a different callback mechanism.
pub fn Callback(comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        loop: *T.Loop,
        completion: *T.Completion,
        result: T.Result,
    ) CallbackAction;
}

/// A callback that does nothing and immediately disarms. This
/// implements xev.Callback and is the default value for completions.
pub fn NoopCallback(comptime T: type) Callback(T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Loop,
            _: *T.Completion,
            _: T.Result,
        ) CallbackAction {
            return .disarm;
        }
    }).noopCallback;
}

/// The result type for callbacks. This should be used by all loop
/// implementations and higher level abstractions in order to control
/// what to do after the loop completes.
pub const CallbackAction = enum(c_int) {
    /// The request is complete and is not repeated. For example, a read
    /// callback only fires once and is no longer watched for reads. You
    /// can always free memory associated with the completion prior to
    /// returning this.
    disarm = 0,

    /// Requeue the same operation request with the same parameters
    /// with the event loop. This makes it easy to repeat a read, timer,
    /// etc. This rearms the request EXACTLY as-is. For example, the
    /// low-level timer interface for io_uring uses an absolute timeout.
    /// If you rearm the timer, it will fire immediately because the absolute
    /// timeout will be in the past.
    ///
    /// The completion is reused so it is not safe to use the same completion
    /// for anything else.
    rearm = 1,
};

/// The state that a completion can be in.
pub const CompletionState = enum(c_int) {
    /// The completion is not being used and is ready to be configured
    /// for new work.
    dead = 0,

    /// The completion is part of an event loop. This may be already waited
    /// on or in the process of being registered.
    active = 1,
};
