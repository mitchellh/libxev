const std = @import("std");

test {
    _ = @import("queue.zig");

    // TODO: until we choose platform
    _ = @import("io_uring.zig");
    _ = @import("linux/timerfd.zig");
}
