pub const Epoll = @This();

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IntrusiveQueue = @import("queue.zig").IntrusiveQueue;
const heap = @import("heap.zig");
const xev = @import("main.zig").Epoll;

const TimerHeap = heap.IntrusiveHeap(Operation.Timer, void, Operation.Timer.less);

fd: std.os.fd_t,

/// The number of active completions. This DOES NOT include completions that
/// are queued in the submissions queue.
active: usize = 0,

/// Our queue of submissions that we want to enqueue on the next tick.
submissions: IntrusiveQueue(Completion) = .{},

/// The queue for completions to delete from the epoll fd.
deletions: IntrusiveQueue(Completion) = .{},

/// The queue for completions representing cancellation requests.
cancellations: IntrusiveQueue(Completion) = .{},

/// Heap of timers.
timers: TimerHeap = .{ .context = {} },

pub fn init(entries: u13) !Epoll {
    _ = entries;

    return .{
        .fd = try std.os.epoll_create1(std.os.O.CLOEXEC),
    };
}

pub fn deinit(self: *Epoll) void {
    std.os.close(self.fd);
}

/// Run the event loop. See RunMode documentation for details on modes.
pub fn run(self: *Epoll, mode: xev.RunMode) !void {
    switch (mode) {
        .no_wait => try self.tick(0),
        .once => try self.tick(1),
        .until_done => while (!self.done()) try self.tick(1),
    }
}

fn done(self: *Epoll) bool {
    return self.active == 0 and
        self.submissions.empty();
}

/// Add a completion to the loop.
pub fn add(self: *Epoll, completion: *Completion) void {
    switch (completion.flags.state) {
        // Already adding, forget about it.
        .adding => return,

        // If it is dead we're good. If we're deleting we'll ignore it
        // while we're processing.
        .dead,
        .deleting,
        => {},

        .in_progress, .active => unreachable,
    }
    completion.flags.state = .adding;

    // We just add the completion to the queue. Failures can happen
    // at tick time...
    self.submissions.push(completion);
}

/// Delete a completion from the loop.
pub fn delete(self: *Epoll, completion: *Completion) void {
    switch (completion.flags.state) {
        // Already deleted
        .deleting => return,

        // If we're active then we will stop it and remove from epoll.
        // If we're adding then we'll ignore it when adding.
        .dead, .active, .adding => {},
    }
    completion.flags.state = .deleting;

    self.deletions.push(completion);
}

/// Add a timer to the loop. The timer will initially execute in "next_ms"
/// from now and will repeat every "repeat_ms" thereafter. If "repeat_ms" is
/// zero then the timer is oneshot. If "next_ms" is zero then the timer will
/// invoke immediately (the callback will be called immediately -- as part
/// of this function call -- to avoid any additional system calls).
pub fn timer(
    self: *Epoll,
    c: *Completion,
    next_ms: u64,
    userdata: ?*anyopaque,
    comptime cb: xev.Callback,
) void {
    // Get the timestamp of the absolute time that we'll execute this timer.
    const next_ts = next_ts: {
        var now: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &now) catch unreachable;
        break :next_ts .{
            .tv_sec = now.tv_sec,
            // TODO: overflow handling
            .tv_nsec = now.tv_nsec + (@intCast(isize, next_ms) * 1000000),
        };
    };

    c.* = .{
        .op = .{
            .timer = .{
                .next = next_ts,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    self.add(c);
}

/// Tick through the event loop once, waiting for at least "wait" completions
/// to be processed by the loop itself.
pub fn tick(self: *Epoll, wait: u32) !void {
    // Submit all the submissions. We copy the submission queue so that
    // any resubmits don't cause an infinite loop.
    var queued = self.submissions;
    self.submissions = .{};
    while (queued.pop()) |c| {
        // We ignore any completions that aren't in the adding state.
        // This usually means that we switched them to be deleted or
        // something.
        if (c.flags.state != .adding) continue;
        self.start(c);
    }

    // Handle all deletions so we don't wait for them.
    while (self.deletions.pop()) |c| {
        if (c.flags.state != .deleting) continue;
        self.stop(c);
    }

    // Wait and process events. We only do this if we have any active.
    if (self.active > 0) {
        var events: [1024]linux.epoll_event = undefined;
        var wait_rem = @intCast(usize, wait);
        while (self.active > 0 and (wait == 0 or wait_rem > 0)) {
            var now: std.os.timespec = undefined;
            try std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &now);
            const now_timer: Operation.Timer = .{ .next = now };

            // Run our expired timers
            while (self.timers.peek()) |t| {
                if (!Operation.Timer.less({}, t, &now_timer)) break;

                // Remove the timer
                assert(self.timers.deleteMin().? == t);

                // Mark completion as done
                const c = t.c;
                c.flags.state = .dead;
                self.active -= 1;

                // Lower our remaining count
                wait_rem -|= 1;

                // Invoke
                const action = c.callback(c.userdata, self, c, .{
                    .timer = .expiration,
                });
                switch (action) {
                    .disarm => {},
                    .rearm => self.start(c),
                }
            }

            // Determine our next timeout based on the timers
            const timeout: i32 = if (wait_rem == 0) 0 else timeout: {
                // If we have a timer, we want to set the timeout to our next
                // timer value. If we have no timer, we wait forever.
                const t = self.timers.peek() orelse break :timeout -1;

                // Determine the time in milliseconds.
                // NOTE(mitchellh): we ignore the nanosecond field here
                break :timeout @intCast(i32, (now.tv_sec -| t.next.tv_sec) * std.time.ms_per_s);
            };

            const n = std.os.epoll_wait(self.fd, &events, timeout);
            if (n < 0) {
                switch (std.os.errno(n)) {
                    .INTR => continue,
                    else => |err| return std.os.unexpectedErrno(err),
                }
            }

            // Process all our events and invoke their completion handlers
            for (events[0..n]) |ev| {
                const c = @intToPtr(*Completion, @intCast(usize, ev.data.ptr));

                // We get the fd and mark this as in progress we can properly
                // clean this up late.r
                const fd = c.fd();
                c.flags.state = .dead;

                const res = c.perform();
                const action = c.callback(c.userdata, self, c, res);
                switch (action) {
                    .disarm => {
                        // We can't use self.stop because we can't trust
                        // that c is still a valid pointer.
                        if (fd) |v| {
                            std.os.epoll_ctl(
                                self.fd,
                                linux.EPOLL.CTL_DEL,
                                v,
                                null,
                            ) catch unreachable;
                        }

                        self.active -= 1;
                    },

                    // For epoll, epoll remains armed by default. We have to
                    // reset the state, that is all.
                    .rearm => c.flags.state = .active,
                }
            }

            if (wait == 0) break;
            wait_rem -|= n;
        }
    }
}

fn start(self: *Epoll, completion: *Completion) void {
    const res_: ?Result = switch (completion.op) {
        .cancel => |v| res: {
            // We stop immediately. We only stop if we are in the
            // "adding" state because cancellation or any other action
            // means we're complete already.
            if (completion.flags.state == .adding) {
                if (v.c.op == .cancel) @panic("cannot cancel a cancellation");
                self.stop(v.c);
            }

            // We always run timers
            break :res .{ .cancel = {} };
        },

        .accept => |*v| res: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.socket,
                &ev,
            )) null else |err| .{ .accept = err };
        },

        .connect => |*v| res: {
            if (std.os.connect(v.socket, &v.addr.any, v.addr.getOsSockLen())) {
                break :res .{ .connect = {} };
            } else |err| switch (err) {
                // If we would block then we register with epoll
                error.WouldBlock => {},

                // Any other error we just return immediately
                else => break :res .{ .connect = err },
            }

            // If connect returns WouldBlock then we register for OUT events
            // and are notified of connection completion that way.
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.OUT,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.socket,
                &ev,
            )) null else |err| .{ .connect = err };
        },

        .read => |*v| res: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .read = err };
        },

        .send => |*v| res: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.OUT,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .send = err };
        },

        .recv => |*v| res: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .recv = err };
        },

        .sendmsg => |*v| res: {
            if (v.buffer) |_| {
                @panic("TODO: sendmsg with buffer");
            }

            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.OUT,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .sendmsg = err };
        },

        .recvmsg => |*v| res: {
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                .data = .{ .ptr = @ptrToInt(completion) },
            };

            break :res if (std.os.epoll_ctl(
                self.fd,
                linux.EPOLL.CTL_ADD,
                v.fd,
                &ev,
            )) null else |err| .{ .recvmsg = err };
        },

        .close => |v| res: {
            std.os.close(v.fd);
            break :res .{ .close = {} };
        },

        .shutdown => |v| res: {
            break :res .{ .shutdown = std.os.shutdown(v.socket, v.how) };
        },

        .timer => |*v| res: {
            // Point back to completion since we need this. In the future
            // we want to use @fieldParentPtr but https://github.com/ziglang/zig/issues/6611
            v.c = completion;

            // Insert the timer into our heap.
            self.timers.insert(v);

            // We always run timers
            break :res null;
        },
    };

    // If we failed to add the completion then we call the callback
    // immediately and mark the error.
    if (res_) |res| {
        switch (completion.callback(
            completion.userdata,
            self,
            completion,
            res,
        )) {
            .disarm => {},

            // If we rearm then we requeue this. Due to the way that tick works,
            // this won't try to re-add immediately it won't happen until the
            // next tick.
            .rearm => self.add(completion),
        }

        return;
    }

    // Mark the completion as active if we reached this point
    completion.flags.state = .active;

    // Increase our active count
    self.active += 1;
}

fn stop(self: *Epoll, completion: *Completion) void {
    // Delete. This should never fail.
    if (completion.fd()) |fd| {
        std.os.epoll_ctl(
            self.fd,
            linux.EPOLL.CTL_DEL,
            fd,
            null,
        ) catch unreachable;
    } else switch (completion.op) {
        .timer => |*v| {
            const c = v.c;

            if (c.flags.state == .active) {
                // Timers needs to be removed from the timer heap.
                self.timers.remove(v);
            }

            // If the timer was never fired, we need to fire it with
            // the cancellation notice.
            if (c.flags.state != .dead) {
                const action = c.callback(c.userdata, self, c, .{ .timer = .cancel });
                switch (action) {
                    .disarm => {},
                    .rearm => {
                        self.start(c);
                        return;
                    },
                }
            }
        },

        else => unreachable,
    }

    // Decrement the active count so we know how many are running for
    // .until_done run semantics.
    if (completion.flags.state == .active) self.active -= 1;

    // Mark the completion as done
    completion.flags.state = .dead;
}

pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation,

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback,

    //---------------------------------------------------------------
    // Internal fields

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,
    } = .{},

    /// Intrusive queue field
    next: ?*Completion = null,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is registered with epoll
        active = 3,

        /// completion is being performed and callback invoked
        in_progress = 4,
    };

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            // This should never happen because we always do these synchronously
            // or in another location.
            .cancel,
            .close,
            .shutdown,
            .timer,
            => unreachable,

            .accept => |*op| .{
                .accept = if (std.os.accept(
                    op.socket,
                    &op.addr,
                    &op.addr_size,
                    op.flags,
                )) |v|
                    v
                else |_|
                    error.Unknown,
            },

            .connect => |*op| .{
                .connect = if (std.os.getsockoptError(op.socket)) {} else |err| err,
            },

            .read => |*op| .{
                .read = if (op.buffer.read(op.fd)) |v|
                    v
                else |_|
                    error.Unknown,
            },

            .send => |*op| .{
                .send = switch (op.buffer) {
                    .slice => |v| std.os.send(op.fd, v, 0),
                    .array => |*v| std.os.send(op.fd, v.array[0..v.len], 0),
                },
            },

            .sendmsg => |*op| .{
                .sendmsg = if (std.os.sendmsg(op.fd, op.msghdr, 0)) |v|
                    v
                else |err|
                    err,
            },

            .recvmsg => |*op| res: {
                const res = std.os.linux.recvmsg(op.fd, op.msghdr, 0);
                break :res .{
                    .recvmsg = if (res == 0)
                        error.EOF
                    else if (res > 0)
                        res
                    else switch (std.os.errno(res)) {
                        else => |err| std.os.unexpectedErrno(err),
                    },
                };
            },

            .recv => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| std.os.recv(op.fd, v, 0),
                    .array => |*v| std.os.recv(op.fd, v, 0),
                };

                break :res .{
                    .recv = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },
        };
    }

    /// Returns the fd associated with the completion (if any).
    fn fd(self: *Completion) ?std.os.fd_t {
        return switch (self.op) {
            .accept => |v| v.socket,
            .connect => |v| v.socket,
            .read => |v| v.fd,
            .recv => |v| v.fd,
            .send => |v| v.fd,
            .sendmsg => |v| v.fd,
            .recvmsg => |v| v.fd,
            .close => |v| v.fd,
            .shutdown => |v| v.socket,

            .cancel,
            .timer,
            => null,
        };
    }
};

pub const OperationType = enum {
    accept,
    connect,
    read,
    send,
    recv,
    sendmsg,
    recvmsg,
    close,
    shutdown,
    timer,
    cancel,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    accept: AcceptError!std.os.socket_t,
    connect: ConnectError!void,
    read: ReadError!usize,
    send: WriteError!usize,
    recv: ReadError!usize,
    sendmsg: WriteError!usize,
    recvmsg: ReadError!usize,
    close: CloseError!void,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
    cancel: CancelError!void,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    cancel: struct {
        c: *Completion,
    },

    accept: struct {
        socket: std.os.socket_t,
        addr: std.os.sockaddr = undefined,
        addr_size: std.os.socklen_t = @sizeOf(std.os.sockaddr),
        flags: u32 = std.os.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: std.os.socket_t,
        addr: std.net.Address,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    send: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    recv: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    sendmsg: struct {
        fd: std.os.fd_t,
        msghdr: *std.os.msghdr_const,

        /// Optionally, a write buffer can be specified and the given
        /// msghdr will be populated with information about this buffer.
        buffer: ?WriteBuffer = null,

        /// Do not use this, it is only used internally.
        iov: [1]std.os.iovec_const = undefined,
    },

    recvmsg: struct {
        fd: std.os.fd_t,
        msghdr: *std.os.msghdr,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        how: std.os.ShutdownHow = .both,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    timer: Timer,

    const Timer = struct {
        /// The absolute time to fire this timer next.
        next: std.os.linux.kernel_timespec,

        /// Internal heap fields.
        heap: heap.IntrusiveHeapField(Timer) = .{},

        /// We point back to completion for now. When issue[1] is fixed,
        /// we can juse use that from our heap fields.
        /// [1]: https://github.com/ziglang/zig/issues/6611
        c: *Completion = undefined,

        fn less(_: void, a: *const Timer, b: *const Timer) bool {
            const ts_a = a.next;
            const ts_b = b.next;
            if (ts_a.tv_sec < ts_b.tv_sec) return true;
            if (ts_a.tv_sec > ts_b.tv_sec) return false;
            return ts_a.tv_nsec < ts_b.tv_nsec;
        }
    };
};

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// To know the size read you have to use the return value of the
    /// read operations (i.e. recv).
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors

    fn read(self: *ReadBuffer, fd: std.os.fd_t) !usize {
        _ = fd;
        return switch (self) {
            else => 0,
        };
    }
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: struct {
        array: [32]u8,
        len: usize,
    },

    // TODO: future will have vectors
};

pub const CancelError = error{};

pub const AcceptError = std.os.EpollCtlError || error{
    Unknown,
};

pub const CloseError = std.os.EpollCtlError || error{
    Unknown,
};

pub const ShutdownError = std.os.EpollCtlError || std.os.ShutdownError || error{
    Unknown,
};

pub const ConnectError = std.os.EpollCtlError || std.os.ConnectError || error{
    Unknown,
};

pub const ReadError = std.os.EpollCtlError || std.os.RecvFromError || error{
    EOF,
    Unknown,
};

pub const WriteError = std.os.EpollCtlError ||
    std.os.SendError ||
    std.os.SendMsgError ||
    error{Unknown};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Unused with epoll
    request,

    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,
};

test "Completion size" {
    const testing = std.testing;

    // Just so we are aware when we change the size
    try testing.expectEqual(@as(usize, 152), @sizeOf(Completion));
}

test "epoll: timer" {
    const testing = std.testing;

    var loop = try init(16);
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: xev.Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);
}

test "epoll: timerfd" {
    const testing = std.testing;

    var loop = try init(0);
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("linux/timerfd.zig").Timerfd;
    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();
    try t.set(0, &.{ .value = .{ .nanoseconds = 1 } }, null);

    // Add the timer
    var called = false;
    var c: Completion = .{
        .op = .{
            .read = .{
                .fd = t.fd,
                .buffer = .{ .array = undefined },
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = r.read catch unreachable;
                _ = c;
                _ = l;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
}

test "epoll: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const os = std.os;
    const testing = std.testing;

    var loop = try init(16);
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(ln);
    try os.setsockopt(ln, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(ln, &address.any, address.getOsSockLen());
    try os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try os.socket(
        address.any.family,
        os.SOCK.NONBLOCK | os.SOCK.STREAM | os.SOCK.CLOEXEC,
        0,
    );
    errdefer os.closeSocket(client_conn);

    // Accept
    var server_conn: os.socket_t = 0;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const conn = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                conn.* = r.accept catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: xev.Completion = .{
        .op = .{
            .connect = .{
                .socket = client_conn,
                .addr = address,
            },
        },

        .userdata = &connected,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.connect catch unreachable;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_connect);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_conn > 0);
    try testing.expect(connected);

    // Send
    var c_send: xev.Completion = .{
        .op = .{
            .send = .{
                .fd = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.send catch unreachable;
                _ = ud;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_send);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    var c_recv: xev.Completion = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.recv catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, c_send.op.send.buffer.slice, recv_buf[0..recv_len]);

    // Shutdown
    var shutdown = false;
    var c_client_shutdown: xev.Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_shutdown);
    try loop.run(.until_done);
    try testing.expect(shutdown);

    // Read should be EOF
    var eof: ?bool = null;
    c_recv = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?bool, @alignCast(@alignOf(?bool), ud.?));
                ptr.* = if (r.recv) |_| false else |err| switch (err) {
                    error.EOF => true,
                    else => false,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.run(.until_done);
    try testing.expect(eof.? == true);

    // Close
    var c_client_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var c_server_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(ln == 0);
    try testing.expect(client_conn == 0);
}

test "epoll: timer cancellation" {
    const testing = std.testing;

    var loop = try init(16);
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .cancel);
}

test "epoll: canceling a completed operation" {
    const testing = std.testing;

    var loop = try init(16);
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .expiration);
}
