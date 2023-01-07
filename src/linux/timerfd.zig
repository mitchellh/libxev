const std = @import("std");
const linux = std.os.linux;

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
    pub fn init(clock: Clock, flags: u32) !Timerfd {
        const res = linux.timerfd_create(@enumToInt(clock), flags);
        return switch (linux.getErrno(res)) {
            .SUCCESS => .{ .fd = @intCast(i32, res) },
            else => error.UnknownError,
        };
    }

    pub fn deinit(self: *const Timerfd) void {
        std.os.close(self.fd);
    }

    /// timerfd_settime
    pub fn set(
        self: *const Timerfd,
        flags: u32,
        new_value: *const Spec,
        old_value: ?*Spec,
    ) !void {
        const res = linux.timerfd_settime(
            self.fd,
            flags,
            @ptrCast(*const linux.itimerspec, new_value),
            @ptrCast(?*linux.itimerspec, old_value),
        );

        return switch (linux.getErrno(res)) {
            .SUCCESS => {},
            else => error.UnknownError,
        };
    }

    /// timerfd_gettime
    pub fn get(self: *const Timerfd) !Spec {
        var out: Spec = undefined;
        const res = linux.timerfd_gettime(self.fd, @ptrCast(*linux.itimerspec, &out));
        return switch (linux.getErrno(res)) {
            .SUCCESS => out,
            else => error.UnknownError,
        };
    }

    /// The clocks available for a Timerfd. This is a non-exhaustive enum
    /// so that unsupported values can be attempted to be passed into the
    /// system calls.
    pub const Clock = enum(i32) {
        realtime = 0,
        monotonic = 1,
        boottime = 7,
        realtime_alarm = 8,
        boottime_alarm = 9,
        _,
    };

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

    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();

    // Set
    try t.set(0, &.{ .value = .{ .seconds = 60 } }, null);
    try testing.expect((try t.get()).value.seconds > 0);

    // Disarm
    var old: Timerfd.Spec = undefined;
    try t.set(0, &.{ .value = .{ .seconds = 0 } }, &old);
    try testing.expect(old.value.seconds > 0);
}
