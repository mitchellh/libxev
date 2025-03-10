const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Timerfd is a wrapper around the timerfd system calls. See the
/// timerfd_create man page for information on timerfd and associated
/// system calls.
///
/// This is a small wrapper around timerfd to make it slightly more
/// pleasant to use, but may not expose all available functionality.
/// For maximum control you should use the syscalls directly.
pub const Timerfd = struct {
    /// The timerfd file descriptor for use with poll, etc.
    fd: i32,

    /// timerfd_create
    pub fn init(
        clock: linux.timerfd_clockid_t,
        flags: linux.TFD,
    ) !Timerfd {
        const res = linux.timerfd_create(clock, flags);
        return switch (posix.errno(res)) {
            .SUCCESS => .{ .fd = @as(i32, @intCast(res)) },
            else => error.UnknownError,
        };
    }

    pub fn deinit(self: *const Timerfd) void {
        posix.close(self.fd);
    }

    /// timerfd_settime
    pub fn set(
        self: *const Timerfd,
        flags: linux.TFD.TIMER,
        new_value: *const Spec,
        old_value: ?*Spec,
    ) !void {
        const res = linux.timerfd_settime(
            self.fd,
            flags,
            @as(*const linux.itimerspec, @ptrCast(new_value)),
            @as(?*linux.itimerspec, @ptrCast(old_value)),
        );

        return switch (posix.errno(res)) {
            .SUCCESS => {},
            else => error.UnknownError,
        };
    }

    /// timerfd_gettime
    pub fn get(self: *const Timerfd) !Spec {
        var out: Spec = undefined;
        const res = linux.timerfd_gettime(self.fd, @as(*linux.itimerspec, @ptrCast(&out)));
        return switch (posix.errno(res)) {
            .SUCCESS => out,
            else => error.UnknownError,
        };
    }

    /// itimerspec
    pub const Spec = extern struct {
        interval: TimeSpec = .{},
        value: TimeSpec = .{},
    };

    /// timespec
    pub const TimeSpec = extern struct {
        seconds: isize = 0,
        nanoseconds: isize = 0,
    };
};

test Timerfd {
    const testing = std.testing;

    var t = try Timerfd.init(.MONOTONIC, .{});
    defer t.deinit();

    // Set
    try t.set(.{}, &.{ .value = .{ .seconds = 60 } }, null);
    try testing.expect((try t.get()).value.seconds > 0);

    // Disarm
    var old: Timerfd.Spec = undefined;
    try t.set(.{}, &.{ .value = .{ .seconds = 0 } }, &old);
    try testing.expect(old.value.seconds > 0);
}
