const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;

/// Process management, such as waiting for process exit.
pub fn Process(comptime xev: type) type {
    return switch (xev.backend) {
        // Supported, uses eventfd
        .io_uring,
        .epoll,
        => ProcessPidFd(xev),

        // Unsupported
        .wasi_poll, .kqueue => struct {},
    };
}

/// Process implementation using pidfd (Linux).
fn ProcessPidFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.ReadError;

        /// eventfd file descriptor
        fd: os.fd_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: os.pid_t) !Self {
            // Note: SOCK_NONBLOCK == PIDFD_NONBLOCK but we should PR that
            // over to Zig.
            const res = os.linux.pidfd_open(pid, os.SOCK.NONBLOCK);
            const fd = switch (os.errno(res)) {
                .SUCCESS => @intCast(os.fd_t, res),
                .INVAL => return error.InvalidArgument,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NODEV => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                else => |err| return os.unexpectedErrno(err),
            };

            return .{
                .fd = fd,
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            std.os.close(self.fd);
        }

        /// Wait for the process to exit.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            // TODO: READ IS NOT CORRECT HERE!
            c.* = .{
                .op = .{
                    .read = .{
                        .fd = self.fd,
                        .buffer = .{ .array = undefined },
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                            l_inner,
                            c_inner,
                            if (r.read) |v| assert(v > 0) else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Common tests
        pub usingnamespace ProcessTests(xev, Self);
    };
}

fn ProcessTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "process wait" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.ChildProcess.init(&.{ "sleep", "2" }, alloc);
            try child.spawn();
            errdefer _ = child.kill() catch {};

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expect(wake);
        }
    };
}
