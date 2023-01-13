//! Common loop structures. The actual loop implementation is in backend-specific
//! files such as linux/io_uring.zig.

const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");

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

/// The result type for callbacks. This should be used by all loop
/// implementations and higher level abstractions in order to control
/// what to do after the loop completes.
pub const CallbackAction = enum {
    /// The request is complete and is not repeated. For example, a read
    /// callback only fires once and is no longer watched for reads. You
    /// can always free memory associated with the completion prior to
    /// returning this.
    disarm,

    /// Requeue the same operation request with the same parameters
    /// with the event loop. This makes it easy to repeat a read, timer,
    /// etc. This rearms the request EXACTLY as-is. For example, the
    /// low-level timer interface for io_uring uses an absolute timeout.
    /// If you rearm the timer, it will fire immediately because the absolute
    /// timeout will be in the past.
    ///
    /// The completion is reused so it is not safe to use the same completion
    /// for anything else.
    rearm,
};
