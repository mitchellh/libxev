const std = @import("std");
const assert = std.debug.assert;
const wasi = std.os.wasi;
const IntrusiveQueue = @import("../queue.zig").IntrusiveQueue;
const heap = @import("../heap.zig");
const xev = @import("../main.zig").WasiPoll;

/// A batch of subscriptions to send to poll_oneoff.
const Batch = struct {
    pub const capacity = 1024;

    /// The array of subscriptions. Sub zero is ALWAYS our loop timeout
    /// so the actual capacity of this for user completions is (len - 1).
    array: [capacity]wasi.subscription_t = undefined,

    /// The length of the used slots in the array including our reserved slot.
    len: usize = 1,

    pub const Error = error{BatchFull};

    /// Initialize a batch entry for the given completion. This will
    /// store the batch index on the completion.
    pub fn get(self: *Batch, c: *Completion) Error!*wasi.subscription_t {
        if (self.len >= self.array.len) return error.BatchFull;
        c.batch_idx = self.len;
        self.len += 1;
        return &self.array[c.batch_idx];
    }

    /// Put an entry back.
    pub fn put(self: *Batch, c: *Completion) void {
        assert(c.batch_idx > 0);
        assert(self.len > 1);

        const old_idx = c.batch_idx;
        c.batch_idx = 0;
        self.len -= 1;

        // If we're empty then we don't worry about swapping.
        if (self.len == 0) return;

        // We're not empty so swap the value we just removed with the
        // last one so our empty slot is always at the end.
        self.array[old_idx] = self.array[self.len];
        const swapped = @intToPtr(*Completion, @intCast(usize, self.array[old_idx].userdata));
        swapped.batch_idx = old_idx;
    }

    test {
        const testing = std.testing;

        var b: Batch = .{};
        var cs: [capacity - 1]Completion = undefined;
        for (cs) |*c, i| {
            c.* = .{ .op = undefined, .callback = undefined };
            const sub = try b.get(c);
            sub.* = .{ .userdata = @ptrToInt(c), .u = undefined };
            try testing.expectEqual(@as(usize, i + 1), c.batch_idx);
        }

        var bad: Completion = .{ .op = undefined, .callback = undefined };
        try testing.expectError(error.BatchFull, b.get(&bad));

        // Put one back
        const old = cs[4].batch_idx;
        const replace = &cs[cs.len - 1];
        b.put(&cs[4]);
        try testing.expect(b.len == capacity - 1);
        try testing.expect(b.array[old].userdata == @ptrToInt(replace));
        try testing.expect(replace.batch_idx == old);

        // Put it back in
        const sub = try b.get(&cs[4]);
        sub.* = .{ .userdata = @ptrToInt(&cs[4]), .u = undefined };
        try testing.expect(cs[4].batch_idx == capacity - 1);
    }
};

pub const Loop = struct {
    const TimerHeap = heap.IntrusiveHeap(Timer, void, Timer.less);

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: IntrusiveQueue(Completion) = .{},

    /// Batch of subscriptions to send to poll.
    batch: Batch = .{},

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    pub fn init(entries: u13) !Loop {
        _ = entries;
        return .{};
    }

    pub fn deinit(self: *Loop) void {
        _ = self;
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    /// Add a completion to the loop. This doesn't DO anything except queue
    /// the completion. Any configuration errors will be exposed via the
    /// callback on the next loop tick.
    pub fn add(self: *Loop, c: *Completion) void {
        c.flags.state = .adding;
        self.submissions.push(c);
    }

    fn done(self: *Loop) bool {
        return self.active == 0 and
            self.submissions.empty();
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
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

        // Wait and process events. We only do this if we have any active.
        if (self.active > 0) {
            var wait_rem = @intCast(usize, wait);
            while (self.active > 0 and (wait == 0 or wait_rem > 0)) {
                const now = try get_now();
                const now_timer: Timer = .{ .next = now };

                // Run our expired timers
                while (self.timers.peek()) |t| {
                    if (!Timer.less({}, t, &now_timer)) break;

                    // Remove the timer
                    assert(self.timers.deleteMin().? == t);

                    // Completion is now dead because it has been processed.
                    // Users can reuse it (unless they specify rearm in
                    // which case we readd it).
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

                // Setup our timeout. If we have nothing to wait for then
                // we just set an expiring timer so that we still poll but it
                // will return ASAP.
                const timeout: wasi.timestamp_t = if (wait_rem == 0) now else timeout: {
                    const t: *const Timer = self.timers.peek() orelse &.{ .next = now };
                    break :timeout t.next;
                };
                self.batch.array[0] = .{
                    .userdata = 0,
                    .u = .{
                        .tag = wasi.EVENTTYPE_CLOCK,
                        .u = .{
                            .clock = .{
                                .id = @bitCast(u32, std.os.CLOCK.MONOTONIC),
                                .timeout = timeout,
                                .precision = 1 * std.time.ns_per_ms,
                                .flags = wasi.SUBSCRIPTION_CLOCK_ABSTIME,
                            },
                        },
                    },
                };

                // Build our batch of subscriptions and poll
                var events: [Batch.capacity]wasi.event_t = undefined;
                const subs = self.batch.array[0..self.batch.len];
                assert(events.len >= subs.len);
                var n: usize = 0;
                switch (wasi.poll_oneoff(&subs[0], &events[0], subs.len, &n)) {
                    .SUCCESS => {},
                    else => |err| return std.os.unexpectedErrno(err),
                }

                // Poll!
                for (events[0..n]) |ev| {
                    // A system event
                    if (ev.userdata == 0) continue;

                    const c = @intToPtr(*Completion, @intCast(usize, ev.userdata));

                    // We assume disarm since this is the safest time to access
                    // the completion. It makes rearms slightly more expensive
                    // but not by very much.
                    c.flags.state = .dead;
                    self.batch.put(c);
                    self.active -= 1;

                    const res = c.perform();
                    const action = c.callback(c.userdata, self, c, res);
                    switch (action) {
                        // We disarm by default
                        .disarm => {},

                        // Rearm we just restart it. We use start instead of
                        // add because then it'll become immediately available
                        // if we loop again.
                        .rearm => self.start(c),
                    }
                }

                if (wait == 0) break;
                wait_rem -|= n;
            }
        }
    }

    fn start(self: *Loop, completion: *Completion) void {
        const res_: ?Result = switch (completion.op) {
            .cancel => |v| res: {
                // We stop immediately. We only stop if we are in the
                // "adding" state because cancellation or any other action
                // means we're complete already.
                //
                // For example, if we're in the deleting state, it means
                // someone is cancelling the cancel. So we do nothing. If
                // we're in the dead state it means we ran already.
                if (completion.flags.state == .adding) {
                    if (v.c.op == .cancel) break :res .{ .cancel = CancelError.InvalidOp };
                    self.stop(v.c);
                }

                // We always run timers
                break :res .{ .cancel = {} };
            },

            .read => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .read = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .write => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .write = err };
                sub.* = completion.subscription();
                break :res null;
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

        // The completion is now active since it is in our poll set.
        completion.flags.state = .active;

        // Increase our active count
        self.active += 1;
    }

    fn stop(self: *Loop, completion: *Completion) void {
        const rearm: bool = switch (completion.op) {
            .timer => |*v| timer: {
                const c = v.c;

                // Timers needs to be removed from the timer heap only if
                // it has been inserted.
                if (v.heap.inserted()) {
                    self.timers.remove(v);
                }

                // If the timer was never fired, we need to fire it with
                // the cancellation notice.
                if (c.flags.state != .dead) {
                    const action = c.callback(c.userdata, self, c, .{ .timer = .cancel });
                    switch (action) {
                        .disarm => {},
                        .rearm => break :timer true,
                    }
                }

                break :timer false;
            },

            else => unreachable,
        };

        // Decrement the active count so we know how many are running for
        // .until_done run semantics.
        if (completion.flags.state == .active) self.active -= 1;

        // Mark the completion as done
        completion.flags.state = .dead;

        // If we're rearming, add it again immediately
        if (rearm) self.start(completion);
    }

    /// Add a timer to the loop. The timer will initially execute in "next_ms"
    /// from now and will repeat every "repeat_ms" thereafter. If "repeat_ms" is
    /// zero then the timer is oneshot. If "next_ms" is zero then the timer will
    /// invoke immediately (the callback will be called immediately -- as part
    /// of this function call -- to avoid any additional system calls).
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        // Get the absolute time we'll execute this timer next.
        var next_ts: wasi.timestamp_t = ts: {
            var now_ts: wasi.timestamp_t = undefined;
            switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &now_ts)) {
                .SUCCESS => {},
                .INVAL => unreachable,
                else => unreachable,
            }

            // TODO: overflow
            now_ts += next_ms * std.time.ns_per_ms;
            break :ts now_ts;
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

    fn get_now() !wasi.timestamp_t {
        var ts: wasi.timestamp_t = undefined;
        return switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &ts)) {
            .SUCCESS => ts,
            .INVAL => error.UnsupportedClock,
            else => |err| std.os.unexpectedErrno(err),
        };
    }
};

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

    /// Index in the batch array.
    batch_idx: usize = 0,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is actively being sent to poll
        active = 3,

        /// completion is being performed and callback invoked
        in_progress = 4,
    };

    fn subscription(self: *Completion) wasi.subscription_t {
        return switch (self.op) {
            .read => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .write => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .cancel, .timer => unreachable,
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            // This should never happen because we always do these synchronously
            // or in another location.
            .cancel,
            .timer,
            => unreachable,

            .read => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| std.os.read(op.fd, v),
                    .array => |*v| std.os.read(op.fd, v),
                };

                break :res .{
                    .read = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .write => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| std.os.write(op.fd, v),
                    .array => |*v| std.os.write(op.fd, v.array[0..v.len]),
                };

                break :res .{
                    .write = if (n_) |n| n else |err| err,
                };
            },
        };
    }
};

pub const OperationType = enum {
    cancel,
    read,
    write,
    timer,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    cancel: CancelError!void,
    read: ReadError!usize,
    write: WriteError!usize,
    timer: TimerError!TimerTrigger,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    cancel: struct {
        c: *Completion,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    write: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    timer: Timer,
};

const Timer = struct {
    /// The absolute time to fire this timer next.
    next: std.os.wasi.timestamp_t,

    /// Internal heap fields.
    heap: heap.IntrusiveHeapField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.next < b.next;
    }
};

pub const CancelError = error{
    /// Invalid operation to cancel. You cannot cancel a cancel operation.
    InvalidOp,
};

pub const ReadError = Batch.Error || std.os.ReadError ||
    error{
    EOF,
    Unknown,
};

pub const WriteError = Batch.Error || std.os.WriteError ||
    error{
    Unknown,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,

    /// Unused
    request,
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

test "wasi: timer" {
    const testing = std.testing;

    var loop = try Loop.init(16);
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

test "wasi: timer cancellation" {
    const testing = std.testing;

    var loop = try Loop.init(16);
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

test "wasi: canceling a completed operation" {
    const testing = std.testing;

    var loop = try Loop.init(16);
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

test "wasi: file" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Create a file
    const path = "zig-cache/wasi-test-file.txt";
    const dir = std.fs.cwd();
    // We can't use dir.createFile yet: https://github.com/ziglang/zig/issues/14324
    const f = f: {
        const w = wasi;
        var oflags = w.O.CREAT | w.O.TRUNC;
        var base: w.rights_t = w.RIGHT.FD_WRITE |
            w.RIGHT.FD_READ |
            w.RIGHT.FD_DATASYNC |
            w.RIGHT.FD_SEEK |
            w.RIGHT.FD_TELL |
            w.RIGHT.FD_FDSTAT_SET_FLAGS |
            w.RIGHT.FD_SYNC |
            w.RIGHT.FD_ALLOCATE |
            w.RIGHT.FD_ADVISE |
            w.RIGHT.FD_FILESTAT_SET_TIMES |
            w.RIGHT.FD_FILESTAT_SET_SIZE |
            w.RIGHT.FD_FILESTAT_GET |
            w.RIGHT.POLL_FD_READWRITE;
        var fdflags: w.fdflags_t = w.FDFLAG.SYNC | w.FDFLAG.RSYNC | w.FDFLAG.DSYNC;
        const fd = try std.os.openatWasi(dir.fd, path, 0x0, oflags, 0x0, base, fdflags);
        break :f std.fs.File{ .handle = fd };
    };
    defer dir.deleteFile(path) catch unreachable;
    defer f.close();

    // Start a reader
    var read_buf: [128]u8 = undefined;
    var read_len: ?usize = null;
    var c_read: xev.Completion = .{
        .op = .{
            .read = .{
                .fd = f.handle,
                .buffer = .{ .slice = &read_buf },
            },
        },

        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?usize, @alignCast(@alignOf(?usize), ud.?));
                ptr.* = r.read catch |err| switch (err) {
                    error.EOF => 0,
                    else => unreachable,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Tick. The reader should NOT read because we are blocked with no data.
    try loop.run(.until_done);
    try testing.expect(read_len.? == 0);

    // Start a writer
    var write_buf = "hello!";
    var write_len: ?usize = null;
    var c_write: xev.Completion = .{
        .op = .{
            .write = .{
                .fd = f.handle,
                .buffer = .{ .slice = write_buf },
            },
        },

        .userdata = &write_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?usize, @alignCast(@alignOf(?usize), ud.?));
                ptr.* = r.write catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    try loop.run(.until_done);
    try testing.expect(write_len.? == write_buf.len);

    // Read and verify we've written
    f.close();
    const f_verify = try dir.openFile(path, .{});
    defer f_verify.close();
    read_len = try f_verify.readAll(&read_buf);
    try testing.expectEqualStrings(write_buf, read_buf[0..read_len.?]);
}
