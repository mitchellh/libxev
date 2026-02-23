const builtin = @import("builtin");
const stream = @import("watcher/stream.zig");

/// The backend types.
pub const Backend = enum {
    io_uring,
    epoll,
    kqueue,
    wasi_poll,
    iocp,

    /// Returns a recommend default backend from inspecting the system.
    pub fn default() Backend {
        return switch (builtin.os.tag) {
            .linux => .io_uring,
            .ios, .macos, .visionos => .kqueue,
            .freebsd => .kqueue,
            .wasi => .wasi_poll,
            .windows => .iocp,
            else => {
                @compileLog(builtin.os);
                @compileError("no default backend for this target");
            },
        };
    }

    /// Candidate backends for this platform in priority order.
    pub fn candidates() []const Backend {
        return switch (builtin.os.tag) {
            .linux => &.{ .io_uring, .epoll },
            .ios, .macos, .visionos => &.{.kqueue},
            .freebsd => &.{.kqueue},
            .wasi => &.{.wasi_poll},
            .windows => &.{.iocp},
            else => {
                @compileLog(builtin.os);
                @compileError("no candidate backends for this target");
            },
        };
    }

    /// Returns the Api (return value of Xev) for the given backend type.
    pub fn Api(comptime self: Backend) type {
        return switch (self) {
            .io_uring => @import("main.zig").IO_Uring,
            .epoll => @import("main.zig").Epoll,
            .kqueue => @import("main.zig").Kqueue,
            .wasi_poll => @import("main.zig").WasiPoll,
            .iocp => @import("main.zig").IOCP,
        };
    }
};
