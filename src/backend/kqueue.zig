//! Backend to use kqueue. This is currently only tested on macOS but
//! support for BSDs is planned (if it doesn't already work).
const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const queue = @import("../queue.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const heap = @import("../heap.zig");
const main = @import("../main.zig");
const xev = main.Kqueue;
const ThreadPool = main.ThreadPool;

pub const Loop = struct {
    const TimerHeap = heap.Intrusive(Timer, void, Timer.less);

    /// The fd of the kqueue.
    kqueue_fd: os.fd_t,

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    /// These are NOT started, they are NOT submitted to kqueue. They are
    /// pending.
    submissions: queue.Intrusive(Completion) = .{},

    /// Our queue of completed completions where the callback hasn't been
    /// called yet, but the "result" field should be set on every completion.
    /// This is used to delay completion callbacks until the next tick.
    completions: queue.Intrusive(Completion) = .{},

    /// Heap of timers. We use heaps instead of the EVFILT_TIMER because
    /// it avoids a lot of syscalls in the case where there are a LOT of
    /// timers.
    timers: TimerHeap = .{ .context = {} },

    /// Cached time
    now: os.timespec,

    /// Initialize a new kqueue-backed event loop. See the Options docs
    /// for what options matter for kqueue.
    pub fn init(options: xev.Options) !Loop {
        _ = options;

        var res: Loop = .{
            .kqueue_fd = try os.kqueue(),
            .now = undefined,
        };
        res.update_now();
        return res;
    }

    /// Deinitialize the loop, this closes the kqueue. Any events that
    /// were unprocessed are lost -- their callbacks will never be called.
    pub fn deinit(self: *Loop) void {
        os.close(self.kqueue_fd);
    }

    /// Add a completion to the loop. The completion is not started until
    /// the loop is run (`run`, `tick`) or an explicit submission request
    /// is made (`submit`).
    pub fn add(self: *Loop, completion: *Completion) void {
        // We just add the completion to the queue. Failures can happen
        // at submission or tick time.
        completion.flags.state = .adding;
        self.submissions.push(completion);
    }

    /// Submit any enqueue completions. This does not fire any callbacks
    /// for completed events (success or error). Callbacks are only fired
    /// on the next tick.
    ///
    /// If an error is returned, some events might be lost. Errors are
    /// exceptional and should generally not happen. If we could recover
    /// which completions were not submitted and restore them we would,
    /// but the kqueue API doesn't provide that level of clarity.
    pub fn submit(self: *Loop) !void {
        // We try to submit as many events at once as we can.
        var events: [256]os.Kevent = undefined;
        var events_len: usize = 0;

        // Submit all the submissions. We copy the submission queue so that
        // any resubmits don't cause an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};

        // On error, we have to restore the queue because we may be batching.
        errdefer self.submissions = queued;

        while (true) {
            queue_pop: while (queued.pop()) |c| {
                if (self.start(c, &events[events_len])) {
                    events_len += 1;

                    // If we fill the changelist then we need to stop
                    // so that we can perform a submission.
                    if (events_len >= events.len) break :queue_pop;
                }
            }

            // If we have no events then we have to have gone through the entire
            // submission queue and we're done.
            if (events_len == 0) break;

            // Zero timeout so that kevent returns immediately.
            var timeout = std.mem.zeroes(os.timespec);
            const completed = try os.kevent(
                self.kqueue_fd,
                events[0..events_len],
                events[0..events_len],
                &timeout,
            );
            events_len = 0;

            // Go through the completed events and queue them.
            for (events[0..completed]) |ev| {
                const c = @intToPtr(*Completion, @intCast(usize, ev.udata));

                // If EV_ERROR is set, then submission failed for this
                // completion. We get the syscall errorcode from data and
                // store it.
                if (ev.flags & os.system.EV_ERROR != 0) {
                    c.result = c.syscall_result(@intCast(i32, ev.data));

                    // We reset the state so that we know that it never
                    // registered with kevent.
                    c.flags.state = .adding;
                } else {
                    // No error, means that this completion is ready to work.
                    c.result = c.perform();
                }

                assert(c.result != null);
                self.completions.push(c);
            }
        }
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    /// Once the loop is run, the pointer MUST remain stable.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // The list of events, used as both a changelist and eventlist.
        var events: [256]os.Kevent = undefined;

        // The number of events in the events array to submit as changes
        // on repeat ticks. Used mostly for efficient disarm.
        var changes: usize = 0;

        var wait_rem = @intCast(usize, wait);

        // TODO(mitchellh): an optimization in the future is for the last
        // batch of submissions to return the changelist, because we can
        // reuse that for the kevent call later...
        try self.submit();

        // Process the completions we already have completed.
        while (self.completions.pop()) |c| {
            // Completion queue items MUST have a result set.
            const action = c.callback(c.userdata, self, c, c.result.?);
            switch (action) {
                // If we're active we have to schedule a delete. Otherwise
                // we do nothing because we were never part of the kqueue.
                .disarm => if (c.flags.state == .active) {
                    if (c.kevent()) |ev| {
                        events[changes] = ev;
                        events[changes].flags = os.system.EV_DELETE;
                        changes += 1;
                        assert(changes <= events.len);
                    }

                    wait_rem -|= 1;
                    self.active -= 1;
                },

                // Only resubmit if we aren't already active (in the queue)
                .rearm => if (c.flags.state != .active) self.submissions.push(c),
            }
        }

        // Explaining the loop condition: we want to loop only if we have
        // active handles (because it means we have something to do)
        // and we have stuff we want to wait for still (wait_rem > 0) or
        // we requested just a nowait tick (because we have to loop at least
        // once).
        //
        // We also loop if there are any requested changes. Requested
        // changes are only ever deletions currently, so we just process
        // those until we have no more.
        while ((self.active > 0 and (wait == 0 or wait_rem > 0)) or
            changes > 0)
        {
            self.update_now();
            const now_timer: Timer = .{ .next = self.now };

            // Run our expired timers
            while (self.timers.peek()) |t| {
                if (!Timer.less({}, t, &now_timer)) break;

                // Remove the timer
                assert(self.timers.deleteMin().? == t);

                // Mark completion as done
                const c = t.c;
                c.flags.state = .dead;

                // We mark it as inactive here because if we rearm below
                // the start() function will reincrement this.
                self.active -= 1;

                // Lower our remaining count since we have processed something.
                wait_rem -|= 1;

                // Invoke
                const action = c.callback(c.userdata, self, c, .{ .timer = .expiration });
                switch (action) {
                    .disarm => {},

                    // We use undefined as the second param because timers
                    // never set a kevent, and we assert false for the same
                    // reason.
                    .rearm => assert(!self.start(c, undefined)),
                }
            }

            // Determine our next timeout based on the timers
            const timeout: ?os.timespec = timeout: {
                if (wait_rem == 0) break :timeout std.mem.zeroes(os.timespec);

                // If we have a timer, we want to set the timeout to our next
                // timer value. If we have no timer, we wait forever.
                const t = self.timers.peek() orelse break :timeout null;

                // Determine the time in milliseconds.
                const ms_now = @intCast(u64, self.now.tv_sec) * std.time.ms_per_s +
                    @intCast(u64, self.now.tv_nsec) / std.time.ns_per_ms;
                const ms_next = @intCast(u64, t.next.tv_sec) * std.time.ms_per_s +
                    @intCast(u64, t.next.tv_nsec) / std.time.ns_per_ms;
                const ms = ms_next -| ms_now;

                break :timeout .{
                    .tv_sec = @intCast(isize, ms / std.time.ms_per_s),
                    .tv_nsec = @intCast(isize, ms % std.time.ms_per_s),
                };
            };

            // Wait for changes. Note that we ALWAYS attempt to get completions
            // back even if are done waiting (wait_rem == 0) because if we have
            // to make a syscall to submit changes, we might as well also check
            // for done events too.
            const completed = completed: while (true) {
                break :completed os.kevent(
                    self.kqueue_fd,
                    events[0..changes],
                    events[0..events.len],
                    if (timeout) |*t| t else null,
                ) catch |err| switch (err) {
                    // If we get ENOENT, it means that one of the changes
                    // we were trying to delete no longer exists. Not a
                    // problem, we just retry without the changes since
                    // the rest should've gone through.
                    error.EventNotFound => {
                        changes = 0;
                        continue;
                    },

                    // Any other error is fatal
                    else => return err,
                };
            };

            // Reset changes since they're not submitted
            changes = 0;

            // Go through the completed events and queue them.
            for (events[0..completed]) |ev| {
                // This can only be set during changelist processing so
                // that means that this event was never actually active.
                // Therefore, we only decrement the waiters by 1 if we
                // processed an active change.
                if (ev.flags & os.system.EV_ERROR != 0) {
                    // We cannot use c here because c is already dead
                    // at this point for this event.
                    continue;
                }
                wait_rem -|= 1;

                const c = @intToPtr(*Completion, @intCast(usize, ev.udata));

                // c is ready to be reused rigt away if we're dearming
                // so we mark it as dead.
                c.flags.state = .dead;

                const result = c.perform();
                const action = c.callback(c.userdata, self, c, result);
                switch (action) {
                    .disarm => {
                        // Mark this event for deletion, it'll happen
                        // on the next tick.
                        events[changes] = ev;
                        events[changes].flags = os.system.EV_DELETE;
                        changes += 1;
                        assert(changes <= events.len);

                        self.active -= 1;
                    },

                    // We rearm by default with kqueue so we just let it be.
                    .rearm => {},
                }
            }

            // If we ran through the loop once we break if we don't care.
            if (wait == 0) break;
        }
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        os.clock_gettime(os.CLOCK.MONOTONIC, &self.now) catch {};
    }

    /// Add a timer to the loop. The timer will execute in "next_ms". This
    /// is oneshot: the timer will not repeat. To repeat a timer, either
    /// schedule another in your callback or return rearm from the callback.
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        // Get the timestamp of the absolute time that we'll execute this timer.
        const next_ts: std.os.timespec = .{
            .tv_sec = self.now.tv_sec,
            // TODO: overflow handling
            .tv_nsec = self.now.tv_nsec + (@intCast(isize, next_ms) * 1000000),
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

    fn done(self: *Loop) bool {
        return self.active == 0 and
            self.submissions.empty();
    }

    /// Start the completion. This returns true if the Kevent was set
    /// and should be queued.
    fn start(self: *Loop, c: *Completion, ev: *os.Kevent) bool {
        const StartAction = union(enum) {
            /// We have set the kevent out parameter
            kevent: void,

            // We are a timer,
            timer: void,

            /// We have a result code from making a system call now.
            result: i32,
        };

        const action: StartAction = switch (c.op) {
            .accept => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .connect => |*v| action: {
                while (true) {
                    const result = os.system.connect(v.socket, &v.addr.any, v.addr.getOsSockLen());
                    switch (os.errno(result)) {
                        // Interrupt, try again
                        .INTR => continue,

                        // This means the connect is blocked and in progress.
                        // We register for the write event which will let us know
                        // when it is complete.
                        .AGAIN, .INPROGRESS => {
                            ev.* = c.kevent().?;
                            break :action .{ .kevent = {} };
                        },

                        // Any other error we report
                        else => break :action .{ .result = result },
                    }
                }
            },

            .send => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .recv => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .shutdown => |v| action: {
                const result = os.system.shutdown(v.socket, switch (v.how) {
                    .recv => os.SHUT.RD,
                    .send => os.SHUT.WR,
                    .both => os.SHUT.RDWR,
                });

                break :action .{ .result = result };
            },

            .close => |v| action: {
                std.os.close(v.fd);
                break :action .{ .result = 0 };
            },

            .timer => |*v| action: {
                // Point back to completion since we need this. In the future
                // we want to use @fieldParentPtr but https://github.com/ziglang/zig/issues/6611
                v.c = c;

                // Insert the timer into our heap.
                self.timers.insert(v);

                // We always run timers
                break :action .{ .timer = {} };
            },
        };

        switch (action) {
            .kevent,
            .timer,
            => {
                // Increase our active count so we now wait for this. We
                // assume it'll successfully queue. If it doesn't we handle
                // that later (see submit)
                self.active += 1;
                c.flags.state = .active;

                // We only return true if this is a kevent, since other
                // actions can come in here.
                return action == .kevent;
            },

            // A result is immediately available. Queue the completion to
            // be invoked.
            .result => |result| {
                c.result = c.syscall_result(result);
                self.completions.push(c);

                return false;
            },
        }
    }
};

/// A completion is a request to perform some work with the loop.
pub const Completion = struct {
    /// Operation to execute.
    op: Operation,

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback,

    //---------------------------------------------------------------
    // Internal fields

    /// Intrusive queue field
    next: ?*Completion = null,

    /// Result code of the syscall. Only used internally in certain
    /// scenarios, should not be relied upon by program authors.
    result: ?Result = null,

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,
    } = .{},

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is submitted with kqueue successfully
        active = 3,
    };

    /// Returns a kevent for this completion, if any. Note that the
    /// kevent isn't immediately useful for all event types. For example,
    /// "connect" requires you to initiate the connection first.
    fn kevent(self: *Completion) ?os.Kevent {
        return switch (self.op) {
            .close,
            .timer,
            .shutdown,
            => null,

            .accept => |v| .{
                .ident = @intCast(usize, v.socket),
                .filter = os.system.EVFILT_READ,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            },

            .connect => |v| .{
                .ident = @intCast(usize, v.socket),
                .filter = os.system.EVFILT_WRITE,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            },

            .send => |v| .{
                .ident = @intCast(usize, v.fd),
                .filter = os.system.EVFILT_WRITE,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            },

            .recv => |v| .{
                .ident = @intCast(usize, v.fd),
                .filter = os.system.EVFILT_READ,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            },
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            .close,
            .timer,
            .shutdown,
            => unreachable,

            .accept => |*op| .{
                .accept = if (os.accept(
                    op.socket,
                    &op.addr,
                    &op.addr_size,
                    op.flags,
                )) |v|
                    v
                else |err|
                    err,
            },

            .connect => |*op| .{
                .connect = if (os.getsockoptError(op.socket)) {} else |err| err,
            },

            .send => |*op| .{
                .send = switch (op.buffer) {
                    .slice => |v| os.send(op.fd, v, 0),
                    .array => |*v| os.send(op.fd, v.array[0..v.len], 0),
                },
            },

            .recv => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| os.recv(op.fd, v, 0),
                    .array => |*v| os.recv(op.fd, v, 0),
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

    /// Returns the error result for the given result code. This is called
    /// in the situation that kqueue fails to enqueue the completion or
    /// a raw syscall fails.
    fn syscall_result(c: *Completion, r: i32) Result {
        const errno = os.errno(r);
        return switch (c.op) {
            .accept => .{
                .accept = switch (errno) {
                    .SUCCESS => r,
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .connect => .{
                .connect = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .send => .{
                .send = switch (errno) {
                    .SUCCESS => @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .recv => .{
                .recv = switch (errno) {
                    .SUCCESS => if (r == 0) error.EOF else @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .shutdown => .{
                .shutdown = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .close => .{
                .close = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .timer => .{
                .timer = switch (errno) {
                    // Success is impossible because timers don't execute syscalls.
                    .SUCCESS => unreachable,
                    else => |err| os.unexpectedErrno(err),
                },
            },
        };
    }
};

pub const OperationType = enum {
    accept,
    connect,
    // read,
    // write,
    send,
    recv,
    // sendmsg,
    // recvmsg,
    close,
    shutdown,
    timer,
    // cancel,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    accept: struct {
        socket: os.socket_t,
        addr: os.sockaddr = undefined,
        addr_size: os.socklen_t = @sizeOf(os.sockaddr),
        flags: u32 = os.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: os.socket_t,
        addr: std.net.Address,
    },

    send: struct {
        fd: os.fd_t,
        buffer: WriteBuffer,
    },

    recv: struct {
        fd: os.fd_t,
        buffer: ReadBuffer,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        how: std.os.ShutdownHow = .both,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    timer: Timer,
};

pub const Result = union(OperationType) {
    accept: AcceptError!os.socket_t,
    connect: ConnectError!void,
    close: CloseError!void,
    send: WriteError!usize,
    recv: ReadError!usize,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
};

pub const AcceptError = os.KEventError || os.AcceptError || error{
    Unexpected,
};

pub const ConnectError = os.KEventError || os.ConnectError || error{
    Unexpected,
};

pub const ReadError = os.KEventError ||
    os.ReadError ||
    os.RecvFromError ||
    error{
    EOF,
    Unexpected,
};

pub const WriteError = os.KEventError ||
    os.WriteError ||
    os.SendError ||
    os.SendMsgError ||
    error{
    Unexpected,
};

pub const ShutdownError = os.ShutdownError || error{
    Unexpected,
};

pub const CloseError = error{
    Unexpected,
};

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

/// Timer that is inserted into the heap.
const Timer = struct {
    /// The absolute time to fire this timer next.
    next: os.timespec,

    /// Internal heap fields.
    heap: heap.IntrusiveField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        // TODO: overflow
        const ts_a = a.next;
        const ts_b = b.next;
        const ns_a = @intCast(u64, ts_a.tv_sec) * std.time.ns_per_s + @intCast(u64, ts_a.tv_nsec);
        const ns_b = @intCast(u64, ts_b.tv_sec) * std.time.ns_per_s + @intCast(u64, ts_b.tv_nsec);
        return ns_a < ns_b;
    }
};

comptime {
    if (@sizeOf(Completion) != 184) {
        @compileLog(@sizeOf(Completion));
        unreachable;
    }
}

test "kqueue: timer" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
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

test "kqueue: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
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
