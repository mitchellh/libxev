const std = @import("std");

/// Timer can be used to schedule callbacks to fire at some point in the
/// future. Timers can be based on different types of clocks, intervals, etc.
///
/// This is the high-level timer abstraction. It attempts to provide a unified
/// cross-platform interface and may incur some overhead in doing so. If you
/// want the absolute highest performance, you should use the OS-specific
/// interfaces directly (this is not recommended for most people).
pub const Timer = @This();

initial: u64,
repeat: u64,

/// Initialize a timer that fires after `initial` milliseconds and repeats
/// every `repeat` milliseconds thereafter. If "repeat" is zero then the
/// timer is oneshot.
///
/// The granularity of the Timer abstraction is milliseconds. The platform-specific
/// interfaces may (usually) have higher resolution timers. We use milliseconds
/// because it is the most cross-platform friendly.
pub fn init(initial: u64, repeat: u64) !Timer {
    return .{ .initial = initial, .repeat = repeat };
}

pub fn start(comptime cb: *const fn () void) void {
    _ = cb;
}
