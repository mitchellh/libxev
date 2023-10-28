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

        .iocp => ProcessIocp(xev),

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
        pub usingnamespace ProcessTests(xev, Self, &.{ "sh", "-c", "exit 0" }, &.{ "sh", "-c", "exit 42" });
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
        pub usingnamespace ProcessTests(xev, Self, &.{ "sh", "-c", "exit 0" }, &.{ "sh", "-c", "exit 42" });
    };
}

const windows = @import("../windows.zig");
fn ProcessIocp(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const WaitError = xev.Sys.JobObjectError;

        job: windows.HANDLE,
        process: windows.HANDLE,

        pub fn init(process: os.pid_t) !Self {
            const current_process = windows.kernel32.GetCurrentProcess();

            // Duplicate the process handle so we don't rely on the caller keeping it alive
            var dup_process: windows.HANDLE = undefined;
            const dup_result = windows.kernel32.DuplicateHandle(
                current_process,
                process,
                current_process,
                &dup_process,
                0,
                windows.FALSE,
                windows.DUPLICATE_SAME_ACCESS,
            );
            if (dup_result == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

            const job = try windows.exp.CreateJobObject(null, null);
            errdefer _ = windows.kernel32.CloseHandle(job);

            // Setting this limit information is required so that we only get process exit
            // notifications for this process - without it we would get notifications for
            // all of its child processes as well.

            var extended_limit_information = std.mem.zeroInit(windows.exp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION, .{
                .BasicLimitInformation = std.mem.zeroInit(windows.exp.JOBOBJECT_BASIC_LIMIT_INFORMATION, .{
                    .LimitFlags = windows.exp.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK,
                }),
            });

            try windows.exp.SetInformationJobObject(
                job,
                .JobObjectExtendedLimitInformation,
                &extended_limit_information,
                @sizeOf(@TypeOf(extended_limit_information)),
            );

            try windows.exp.AssignProcessToJobObject(job, dup_process);

            return .{
                .process = dup_process,
                .job = job,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = windows.kernel32.CloseHandle(self.job);
            _ = windows.kernel32.CloseHandle(self.process);
        }

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
                    .job_object = .{
                        .job = self.job,
                        .userdata = self.process,
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
                        if (r.job_object) |result| {
                            switch (result) {
                                 .JOB_OBJECT_MSG_EXIT_PROCESS,
                                 .JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS,
                                => |pid| {
                                    // Don't need to check PID as we've specified JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK
                                    _ = pid;

                                    var exit_code: windows.DWORD = undefined;
                                    const process: windows.HANDLE = @ptrCast(c_inner.op.job_object.userdata);
                                    const has_code = windows.kernel32.GetExitCodeProcess(process, &exit_code) != 0;
                                    if (!has_code) std.log.warn("unable to get exit code for process={}", .{windows.kernel32.GetLastError()});

                                    return @call(.always_inline, cb, .{
                                        common.userdataValue(Userdata, ud),
                                        l_inner,
                                        c_inner,
                                        if (has_code) exit_code else WaitError.Unexpected,
                                    });
                                },
                                else => return .rearm,
                            }
                        } else |err| {
                            return @call(.always_inline, cb, .{
                                common.userdataValue(Userdata, ud),
                                l_inner,
                                c_inner,
                                err,
                            });
                        }
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Common tests
        pub usingnamespace ProcessTests(xev, Self, &.{ "cmd.exe", "/C", "exit 0" }, &.{ "cmd.exe", "/C", "exit 42" });
    };
}

fn ProcessTests(
    comptime xev: type,
    comptime Impl: type,
    comptime argv_0: []const []const u8,
    comptime argv_42: []const []const u8,
) type {
    return struct {
        test "process wait" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.ChildProcess.init(argv_0, alloc);
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

            var child = std.ChildProcess.init(argv_42, alloc);
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
