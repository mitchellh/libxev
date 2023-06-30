const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const common = @import("common.zig");

/// Process management, such as waiting for process exit.
pub fn Process(comptime xev: type) type {
    return switch (xev.backend) {
        // Supported, uses pidfd
        .io_uring,
        .epoll,
        => ProcessPidFd(xev),

        .kqueue => ProcessKqueue(xev),

        // Unsupported
        .wasi_poll => struct {},
    };
}

/// Process implementation using pidfd (Linux).
fn ProcessPidFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.PollError || error{
            InvalidChild,
        };

        /// pidfd file descriptor
        fd: os.fd_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: os.pid_t) !Self {
            // Note: SOCK_NONBLOCK == PIDFD_NONBLOCK but we should PR that
            // over to Zig.
            const res = os.linux.pidfd_open(pid, os.SOCK.NONBLOCK);
            const fd = switch (os.errno(res)) {
                .SUCCESS => @as(os.fd_t, @intCast(res)),
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

        /// Clean up the process watcher.
        pub fn deinit(self: *Self) void {
            std.os.close(self.fd);
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
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
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            const events: u32 = comptime switch (xev.backend) {
                .io_uring => os.POLL.IN,
                .epoll => os.linux.EPOLL.IN,
                else => unreachable,
            };

            c.* = .{
                .op = .{
                    .poll = .{
                        .fd = self.fd,
                        .events = events,
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
                        const arg: WaitError!u32 = arg: {
                            // If our poll failed, report that error.
                            _ = r.poll catch |err| break :arg err;

                            // We need to wait on the pidfd because it is noted as ready
                            const fd = c_inner.op.poll.fd;
                            var info: os.linux.siginfo_t = undefined;
                            const res = os.linux.waitid(.PIDFD, fd, &info, os.linux.W.EXITED);

                            break :arg switch (os.errno(res)) {
                                .SUCCESS => @as(u32, @intCast(info.fields.common.second.sigchld.status)),
                                .CHILD => error.InvalidChild,

                                // The fd isn't ready to read, I guess?
                                .AGAIN => return .rearm,
                                else => |err| err: {
                                    std.log.warn("unexpected process wait errno={}", .{err});
                                    break :err error.Unexpected;
                                },
                            };
                        };

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            arg,
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

fn ProcessKqueue(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.ProcError;

        /// The pid to watch.
        pid: os.pid_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: os.pid_t) !Self {
            return .{
                .pid = pid,
            };
        }

        /// Does nothing for Kqueue.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
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
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .proc = .{
                        .pid = self.pid,
                        .flags = os.system.NOTE_EXIT | os.system.NOTE_EXITSTATUS,
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
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.proc) |v| v else |err| err,
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

            var child = std.ChildProcess.init(&.{ "sh", "-c", "exit 0" }, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 0), code.?);
        }

        test "process wait with non-zero exit code" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.ChildProcess.init(&.{ "sh", "-c", "exit 42" }, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = undefined;
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 42), code.?);
        }
    };
}
